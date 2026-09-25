from __future__ import annotations

from aiohttp import web

from .rokid_adapter import BridgeProtocolError, RokidPlatformAdapter
from .services.device_registry import DeviceRegistry


class BridgeServer:
    """HTTP/SSE server owned by the plugin, with no separate deployment."""

    def __init__(self, registry: DeviceRegistry, adapter: RokidPlatformAdapter, config: dict) -> None:
        self.registry, self.adapter, self.config, self.runner = registry, adapter, config, None

    async def start(self) -> None:
        # JSON chat bodies stay small; photo commands need bounded multipart uploads.
        app = web.Application(client_max_size=10 * 1024 * 1024)
        app.router.add_get("/health", self.health)
        app.router.add_post("/v1/pair/request", self.pair_request)
        app.router.add_post("/v1/pair/claim", self.pair_claim)
        app.router.add_post("/v1/chat", self.chat)
        app.router.add_post("/v1/command/result", self.command_result)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, str(self.config.get("listen_host", "0.0.0.0")), int(self.config.get("listen_port", 6191))).start()

    async def stop(self) -> None:
        if self.runner:
            await self.runner.cleanup()
            self.runner = None

    async def health(self, request): return self.json({"protocol_version": 1, "status": "ok"})

    async def pair_request(self, request):
        if not self.config.get("allow_pairing", True): return self.error("当前不允许新设备配对", 403)
        try:
            data = await self.payload(request)
            pairing = await self.registry.request_pairing(str(data.get("device_id", "")), str(data.get("display_name", "Rokid Glasses")))
        except ValueError as exc: return self.error(str(exc), 400)
        return self.json({"protocol_version": 1, "status": "pairing", "pairing_code": pairing.code, "expires_at": pairing.expires_at})

    async def pair_claim(self, request):
        try: claimed = await self.registry.claim_pairing(str((await self.payload(request)).get("pairing_code", "")))
        except ValueError as exc: return self.error(str(exc), 400)
        if claimed is None: return self.json({"protocol_version": 1, "status": "pending"})
        device, credential = claimed
        return self.json({"protocol_version": 1, "status": "paired", "device_id": device.device_id, "credential": credential})

    async def chat(self, request):
        try: events = await self.adapter.open_chat(await self.payload(request))
        except BridgeProtocolError as exc: return self.error(str(exc), exc.status_code)
        response = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Access-Control-Allow-Origin": "*"})
        await response.prepare(request)
        async for chunk in events: await response.write(chunk)
        await response.write_eof()
        return response

    async def command_result(self, request):
        try:
            if request.content_type.startswith("multipart/"):
                fields, image_bytes, mime_type = await self.read_multipart_result(request)
                payload = {
                    "protocol_version": int(fields.get("protocol_version", 0)),
                    "device_id": str(fields.get("device_id", "")),
                    "credential": str(fields.get("credential", "")),
                    "command_id": str(fields.get("command_id", "")),
                    "status": str(fields.get("status", "error")),
                    "message": str(fields.get("message", "")),
                    "image_bytes": image_bytes,
                    "mime_type": mime_type,
                }
            else:
                payload = await self.payload(request)
            if payload.get("protocol_version") != 1:
                raise BridgeProtocolError(400, "不支持的 protocol_version")
            await self.adapter.submit_command_result(
                str(payload.get("device_id", "")), str(payload.get("credential", "")),
                str(payload.get("command_id", "")), payload,
            )
        except BridgeProtocolError as exc:
            return self.error(str(exc), exc.status_code)
        except web.HTTPException:
            raise
        except Exception:
            return self.error("设备命令结果格式无效", 400)
        return self.json({"protocol_version": 1, "status": "ok"})

    @staticmethod
    async def read_multipart_result(request) -> tuple[dict[str, str], bytes, str]:
        """Read a command-result upload without synchronously blocking aiohttp."""
        fields: dict[str, str] = {}
        image_bytes, mime_type = b"", ""
        reader = await request.multipart()
        while part := await reader.next():
            if part.name != "image":
                fields[str(part.name or "")] = await part.text()
                continue
            mime_type = str(part.headers.get("Content-Type", "") or "")
            if not mime_type.startswith("image/"):
                raise BridgeProtocolError(400, "照片必须是图片格式")
            chunks: list[bytes] = []
            size = 0
            while chunk := await part.read_chunk(64 * 1024):
                size += len(chunk)
                if size > 8 * 1024 * 1024:
                    raise BridgeProtocolError(400, "照片大小必须在 1 到 8 MiB 之间")
                chunks.append(chunk)
            image_bytes = b"".join(chunks)
            if not image_bytes:
                raise BridgeProtocolError(400, "照片大小必须在 1 到 8 MiB 之间")
        return fields, image_bytes, mime_type

    async def payload(self, request):
        try: data = await request.json()
        except Exception: raise web.HTTPBadRequest(text="请求体必须是 JSON 对象")
        if not isinstance(data, dict) or data.get("protocol_version") != 1: raise web.HTTPBadRequest(text="不支持的 protocol_version")
        return data

    @staticmethod
    def json(data): return web.json_response(data, headers={"Access-Control-Allow-Origin": "*"})
    @staticmethod
    def error(message, status): return web.json_response({"status": "error", "message": message}, status=status, headers={"Access-Control-Allow-Origin": "*"})
