from __future__ import annotations

import asyncio
import json
import time
import uuid
from collections.abc import AsyncIterator

from astrbot.api.event import MessageChain
from astrbot.api.message_components import Plain
from astrbot.api.platform import AstrBotMessage, MessageMember, MessageType, Platform, PlatformMetadata

from .rokid_event import RokidPlatformEvent
from .services.runtime import get_registry


class BridgeProtocolError(Exception):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class RokidPlatformAdapter(Platform):
    """Internal-only adapter; users never create an AstrBot bot instance."""

    def __init__(self, config: dict, event_queue: asyncio.Queue) -> None:
        super().__init__(config, event_queue)
        self._requests: dict[str, asyncio.Queue[dict]] = {}
        self._request_devices: dict[str, str] = {}
        self._command_waiters: dict[str, tuple[str, asyncio.Future]] = {}
        self._metadata = PlatformMetadata("rokid_bridge", "Rokid Glasses Bridge", str(config.get("id") or "rokid_bridge_internal"), support_streaming_message=True)

    def meta(self) -> PlatformMetadata:
        return self._metadata

    async def run(self) -> None:
        self.status = type(self.status).RUNNING
        await asyncio.Event().wait()

    async def terminate(self) -> None:
        for queue in self._requests.values():
            queue.put_nowait({"type": "error", "code": "adapter_stopped"})
        self._requests.clear()
        self._request_devices.clear()
        for _, future in self._command_waiters.values():
            if not future.done():
                future.set_exception(BridgeProtocolError(503, "Bridge 已停止"))
        self._command_waiters.clear()

    async def open_chat(self, payload: dict) -> AsyncIterator[bytes]:
        device_id, credential = payload.get("device_id"), payload.get("credential")
        if not isinstance(device_id, str) or not isinstance(credential, str):
            raise BridgeProtocolError(401, "设备未授权")
        device = await get_registry().authenticate(device_id, credential)
        if device is None:
            raise BridgeProtocolError(401, "设备未授权")
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip() or len(text) > 8000:
            raise BridgeProtocolError(400, "text 必须是 1 到 8000 字符")
        request_id = uuid.uuid4().hex
        queue: asyncio.Queue[dict] = asyncio.Queue()
        self._requests[request_id] = queue
        self._request_devices[request_id] = device.device_id
        message = AstrBotMessage()
        message.type, message.self_id, message.session_id, message.message_id = MessageType.FRIEND_MESSAGE, self.client_self_id, device.device_id, request_id
        message.sender = MessageMember(user_id=device.device_id, nickname=device.display_name)
        message.message_str, message.message = text.strip(), [Plain(text=text.strip())]
        message.raw_message = {"protocol_version": 1, "device_id": device.device_id}
        event = RokidPlatformEvent(message.message_str, message, self.meta(), device.device_id, self, request_id)
        # AstrBot permission filters inspect event.role. The setting is bound to
        # the authenticated device record, not a display name or mutable client data.
        event.role = "admin" if device.is_admin else "member"
        self.commit_event(event)
        return self._sse_events(request_id, queue)

    async def publish_text(self, request_id: str, text: str) -> None:
        if queue := self._requests.get(request_id):
            await queue.put({"type": "delta", "text": text})

    async def publish_done(self, request_id: str) -> None:
        if queue := self._requests.get(request_id):
            await queue.put({"type": "done"})

    async def request_device_command(self, request_id: str, command: str, payload: dict, timeout_seconds: int = 45) -> dict:
        """Deliver a command through an active chat stream and await its result."""
        queue = self._requests.get(request_id)
        if queue is None:
            raise BridgeProtocolError(409, "眼镜当前未连接，无法执行设备操作")
        command_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        self._command_waiters[command_id] = (request_id, future)
        await queue.put({"type": "command", "command_id": command_id, "command": command, "payload": payload})
        try:
            return await asyncio.wait_for(future, timeout=max(5, min(timeout_seconds, 120)))
        except TimeoutError as exc:
            raise BridgeProtocolError(504, "眼镜设备操作超时") from exc
        finally:
            self._command_waiters.pop(command_id, None)

    async def submit_command_result(self, device_id: str, credential: str, command_id: str, result: dict) -> None:
        device = await get_registry().authenticate(device_id, credential)
        if device is None:
            raise BridgeProtocolError(401, "设备未授权")
        waiter = self._command_waiters.get(command_id)
        if waiter is None:
            raise BridgeProtocolError(404, "设备命令不存在或已过期")
        request_id, future = waiter
        if self._request_devices.get(request_id) != device.device_id:
            raise BridgeProtocolError(403, "设备无权提交此命令结果")
        if not future.done():
            future.set_result(result)

    async def send_by_session(self, session, message_chain: MessageChain) -> None:
        await super().send_by_session(session, message_chain)

    async def _sse_events(self, request_id: str, queue: asyncio.Queue[dict]) -> AsyncIterator[bytes]:
        timeout = max(10, min(int(self.config.get("request_timeout_seconds", 120)), 600))
        started = time.monotonic()
        try:
            yield self._sse("ready", {"protocol_version": 1, "request_id": request_id})
            while remaining := timeout - (time.monotonic() - started):
                try:
                    # Some embedded SSE clients close an otherwise healthy stream after
                    # about five seconds without a body chunk. Keep the connection alive
                    # while AstrBot is still producing its first reply.
                    event = await asyncio.wait_for(queue.get(), timeout=min(3, remaining))
                except TimeoutError:
                    yield b": keepalive\n\n"
                    continue
                if event["type"] == "delta":
                    yield self._sse("delta", {"text": event["text"]})
                elif event["type"] == "command":
                    yield self._sse("command", {"command_id": event["command_id"], "command": event["command"], "payload": event["payload"]})
                else:
                    yield self._sse(event["type"], {"code": event.get("code")} if event["type"] == "error" else {})
                    return
            yield self._sse("error", {"code": "request_timeout"})
        finally:
            self._requests.pop(request_id, None)
            self._request_devices.pop(request_id, None)
            for _, (owner_request_id, future) in list(self._command_waiters.items()):
                if owner_request_id == request_id and not future.done():
                    future.set_exception(BridgeProtocolError(409, "眼镜连接已关闭"))

    @staticmethod
    def _sse(event: str, data: dict) -> bytes:
        return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()
