from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING

from astrbot.api.event import AstrMessageEvent, MessageChain
from astrbot.api.message_components import Plain
from astrbot.api.platform import AstrBotMessage, PlatformMetadata

if TYPE_CHECKING:
    from .rokid_adapter import RokidPlatformAdapter


class RokidPlatformEvent(AstrMessageEvent):
    """Routes ordinary AstrBot results to the request's SSE stream."""

    def __init__(
        self,
        message_str: str,
        message_obj: AstrBotMessage,
        platform_meta: PlatformMetadata,
        session_id: str,
        adapter: "RokidPlatformAdapter",
        request_id: str,
    ) -> None:
        super().__init__(message_str, message_obj, platform_meta, session_id)
        self._adapter = adapter
        self._request_id = request_id
        self._deferred_done_task: asyncio.Task | None = None
        self._done_sent = False
        self._segment_close_delay_seconds = max(
            0.1,
            float(adapter.config.get("segment_close_delay_seconds", 1.2)),
        )

    def _cancel_deferred_done(self) -> None:
        if self._deferred_done_task and not self._deferred_done_task.done():
            self._deferred_done_task.cancel()
        self._deferred_done_task = None

    def _schedule_deferred_done(self) -> None:
        """Finish ordinary segmented replies after a short idle window."""
        self._cancel_deferred_done()
        self._deferred_done_task = asyncio.create_task(self._publish_done_when_idle())

    async def _publish_done_when_idle(self) -> None:
        try:
            await asyncio.sleep(self._segment_close_delay_seconds)
        except asyncio.CancelledError:
            return

        if not self._done_sent:
            self._done_sent = True
            await self._adapter.publish_done(self._request_id)

    async def send(self, message: MessageChain) -> None:
        # Some AstrBot routes deliver a response as several ordinary send()
        # calls (for example, QQ/WeChat-style segments). Completing SSE here
        # used to close the glasses connection after the first segment.
        self._cancel_deferred_done()
        text = "".join(
            component.text
            for component in message.chain
            if isinstance(component, Plain)
        )
        if text:
            await self._adapter.publish_text(self._request_id, text)
        self._schedule_deferred_done()
        await super().send(message)

    async def send_streaming(self, generator, use_fallback: bool = False) -> None:
        self._cancel_deferred_done()
        async for chain in generator:
            if isinstance(chain, MessageChain):
                text = "".join(
                    component.text
                    for component in chain.chain
                    if isinstance(component, Plain)
                )
                if text:
                    await self._adapter.publish_text(self._request_id, text)
        if not self._done_sent:
            self._done_sent = True
            await self._adapter.publish_done(self._request_id)
