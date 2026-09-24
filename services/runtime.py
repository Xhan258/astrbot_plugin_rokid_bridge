from __future__ import annotations

from .device_registry import DeviceRegistry

_registry: DeviceRegistry | None = None


def set_registry(registry: DeviceRegistry) -> None:
    global _registry
    _registry = registry


def get_registry() -> DeviceRegistry:
    if _registry is None:
        raise RuntimeError("Rokid Bridge 尚未初始化")
    return _registry
