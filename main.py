from __future__ import annotations

import asyncio
import os
import tempfile

from astrbot.api import llm_tool, logger
from astrbot.api.star import Context, Star
from astrbot.api.web import error_response, json_response, request

from .bridge_server import BridgeServer
from .rokid_adapter import RokidPlatformAdapter
from .rokid_event import RokidPlatformEvent
from .services.device_registry import DeviceRegistry
from .services.runtime import set_registry

class RokidGlassesBridgePlugin(Star):
    """Bootstraps shared device storage and authenticated WebUI management APIs."""

    def __init__(self, context: Context, config: dict | None = None) -> None:
        super().__init__(context, config)
        self.config = config or {}
        self.registry = DeviceRegistry(
            self,
            pairing_ttl_seconds=int(self.config.get("pairing_ttl_seconds", 300)),
        )
        set_registry(self.registry)
        self.adapter = RokidPlatformAdapter(
            {
                "id": "rokid_bridge_internal",
                "request_timeout_seconds": self.config.get("request_timeout_seconds", 120),
                "segment_close_delay_seconds": max(
                    100,
                    int(self.config.get("segment_close_delay_milliseconds", 3000)),
                ) / 1000,
            },
            context.platform_manager.event_queue,
        )
        context.platform_manager.platform_insts.append(self.adapter)
        self.server = BridgeServer(self.registry, self.adapter, self.config)
        asyncio.create_task(self.server.start())

        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/devices",
            self.list_devices_api,
            ["GET"],
            "列出已绑定的 Rokid 设备",
        )
        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/pairings/<code>/confirm",
            self.confirm_pairing_api,
            ["POST"],
            "确认 Rokid 六位配对码",
        )
        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/devices/<device_id>/revoke",
            self.revoke_device_api,
            ["POST"],
            "撤销 Rokid 设备凭证",
        )
        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/devices/<device_id>/grant-admin",
            self.grant_device_admin_api,
            ["POST"],
            "授予 Rokid 设备管理员权限",
        )
        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/devices/<device_id>/revoke-admin",
            self.revoke_device_admin_api,
            ["POST"],
            "撤销 Rokid 设备管理员权限",
        )
        context.register_web_api(
            "/astrbot_plugin_rokid_bridge/devices/<device_id>/rename",
            self.rename_device_api,
            ["POST"],
            "修改 Rokid 设备使用者名称",
        )

    async def list_devices_api(self):
        devices = await self.registry.list_devices()
        return json_response(
            {
                "devices": [
                    {
                        "device_id": item.device_id,
                        "display_name": item.display_name,
                        "paired_at": item.paired_at,
                        "last_seen_at": item.last_seen_at,
                        "is_admin": item.is_admin,
                    }
                    for item in devices
                ],
            },
        )

    async def confirm_pairing_api(self, code: str):
        try:
            pairing = await self.registry.confirm_pairing(code)
        except ValueError as exc:
            return error_response(str(exc), status_code=400)
        return json_response(
            {
                "status": "paired",
                "device": {
                    "device_id": pairing.device_id,
                    "display_name": pairing.display_name,
                },
            },
        )

    async def revoke_device_api(self, device_id: str):
        if await self.registry.revoke(device_id):
            return json_response({"status": "revoked"})
        return error_response("设备不存在", status_code=404)

    async def grant_device_admin_api(self, device_id: str):
        device = await self.registry.set_admin(device_id, True)
        if device is None:
            return error_response("设备不存在", status_code=404)
        logger.info("Rokid device granted admin: id=%s name=%s", device.device_id, device.display_name)
        return json_response({"status": "ok", "is_admin": True})

    async def revoke_device_admin_api(self, device_id: str):
        device = await self.registry.set_admin(device_id, False)
        if device is None:
            return error_response("设备不存在", status_code=404)
        logger.info("Rokid device revoked admin: id=%s name=%s", device.device_id, device.display_name)
        return json_response({"status": "ok", "is_admin": False})

    async def rename_device_api(self, device_id: str):
        payload = await request.json(default={})
        display_name = payload.get("display_name") if isinstance(payload, dict) else None
        if not isinstance(display_name, str) or not display_name.strip():
            return error_response("使用者名称不能为空", status_code=400)
        device = await self.registry.rename(device_id, display_name)
        if device is None:
            return error_response("设备不存在", status_code=404)
        logger.info("Rokid device renamed: id=%s name=%s", device.device_id, device.display_name)
        return json_response({"status": "ok", "display_name": device.display_name})

    async def terminate(self):
        await self.server.stop()
        await self.adapter.terminate()
        if self.adapter in self.context.platform_manager.platform_insts:
            self.context.platform_manager.platform_insts.remove(self.adapter)

    @staticmethod
    def _device_tool_error(event) -> str | None:
        if not isinstance(event, RokidPlatformEvent):
            return "此工具只能在已连接的 Rokid 眼镜会话中使用。"
        if not event.is_admin():
            return "权限不足：当前眼镜设备未设为管理员，不能使用设备工具。"
        return None

    @llm_tool("rokid_show_text")
    async def rokid_show_text(self, event, text: str, duration_seconds: int = 8) -> str:
        """在当前管理员 Rokid 眼镜的 HUD 上显示一段临时文本。

        仅在用户正通过该眼镜聊天、且确实需要在视野中显示简短结果时调用。
        不要用于长篇回复；普通回复会自动显示在 HUD 中。
        """
        if error := self._device_tool_error(event):
            return error
        text = str(text).strip()
        if not text:
            return "显示失败：文本不能为空。"
        try:
            duration = max(1, min(int(duration_seconds), 30))
        except (TypeError, ValueError):
            duration = 8
        result = await self.adapter.request_device_command(
            event._request_id,
            "show_text",
            {"text": text[:500], "duration_seconds": duration},
        )
        return "已显示在眼镜 HUD。" if result.get("status") == "ok" else f"HUD 显示失败：{result.get('message', '未知错误')}"

    @llm_tool("rokid_take_photo")
    async def rokid_take_photo(self, event, purpose: str = "请描述照片中的内容") -> str:
        """使用当前管理员 Rokid 眼镜拍一张照片并识别其内容。

        当用户要求查看眼前物体、读取远处文字或判断现实场景时调用。该工具只在当前
        已连接的眼镜会话中拍照；不会在后台拍摄。需要当前聊天模型支持图片。
        """
        if error := self._device_tool_error(event):
            return error
        result = await self.adapter.request_device_command(
            event._request_id, "take_photo", {"mode": "telephoto"}, timeout_seconds=60
        )
        if result.get("status") != "ok":
            return f"拍照失败：{result.get('message', '未知错误')}"
        image_bytes = result.get("image_bytes")
        mime_type = result.get("mime_type") or "image/jpeg"
        if not isinstance(image_bytes, bytes) or not image_bytes:
            return "拍照失败：眼镜没有返回有效图片。"
        suffix = ".jpg" if mime_type in ("image/jpeg", "image/jpg") else ".png"
        path = ""
        try:
            with tempfile.NamedTemporaryFile(prefix="rokid-photo-", suffix=suffix, delete=False) as photo:
                photo.write(image_bytes)
                path = photo.name
            provider_id = await self.context.get_current_chat_provider_id(event.unified_msg_origin)
            response = await self.context.llm_generate(
                chat_provider_id=provider_id,
                prompt=(
                    "这是用户通过眼镜刚拍摄的一张现实照片。"
                    f"{str(purpose)[:500]}。只返回可靠、简洁的中文观察；无法确认的内容请明确说明。"
                ),
                image_urls=[path],
            )
            return (response.completion_text or "").strip() or "图片已收到，但视觉模型没有返回可用描述。"
        except Exception as exc:
            return f"识图失败：当前模型可能不支持图片，或视觉请求异常（{exc}）。"
        finally:
            if path:
                try:
                    os.remove(path)
                except OSError:
                    pass
