from __future__ import annotations

import asyncio
import hashlib
import secrets
import time
from dataclasses import asdict, dataclass
from typing import Any, Protocol


class KeyValueStore(Protocol):
    async def get_kv_data(self, key: str, default: Any) -> Any: ...

    async def put_kv_data(self, key: str, value: Any) -> None: ...


@dataclass
class DeviceRecord:
    device_id: str
    display_name: str
    credential_hash: str
    paired_at: int
    last_seen_at: int | None = None
    is_admin: bool = False


@dataclass
class PairingRecord:
    code: str
    device_id: str
    display_name: str
    expires_at: int
    confirmed: bool = False


class DeviceRegistry:
    """Persists revocable device credentials through AstrBot plugin storage."""

    _DEVICES_KEY = "rokid_bridge.devices.v1"
    _PAIRINGS_KEY = "rokid_bridge.pairings.v1"

    def __init__(self, store: KeyValueStore, pairing_ttl_seconds: int = 300) -> None:
        self._store = store
        self._ttl = max(30, min(pairing_ttl_seconds, 900))
        # Device authentication and Dashboard actions both update the same
        # persisted record.  Serialise read-modify-write operations so an
        # authentication heartbeat can never restore a stale `is_admin` flag.
        self._devices_lock = asyncio.Lock()

    @staticmethod
    def _hash_credential(credential: str) -> str:
        return hashlib.sha256(credential.encode("utf-8")).hexdigest()

    async def request_pairing(
        self,
        device_id: str,
        display_name: str,
        now: int | None = None,
    ) -> PairingRecord:
        now = now or int(time.time())
        device_id = self._validate_identifier(device_id, "device_id")
        display_name = self._clean_display_name(display_name)
        pairings = await self._live_pairings(now)

        # A device may only have one live code. Regenerate it instead of
        # accumulating valid credentials for the same physical client.
        pairings = [item for item in pairings if item.device_id != device_id]
        code = self._new_unique_code(pairings)
        pairing = PairingRecord(code, device_id, display_name, now + self._ttl)
        pairings.append(pairing)
        await self._save_pairings(pairings)
        return pairing

    async def confirm_pairing(
        self,
        code: str,
        now: int | None = None,
    ) -> PairingRecord:
        now = now or int(time.time())
        code = self._validate_code(code)
        pairings = await self._live_pairings(now)
        target = next((item for item in pairings if item.code == code), None)
        if target is None:
            raise ValueError("配对码不存在或已过期")
        if target.confirmed:
            raise ValueError("配对码已经使用")

        target.confirmed = True
        await self._save_pairings(pairings)
        return target

    async def claim_pairing(
        self,
        code: str,
        now: int | None = None,
    ) -> tuple[DeviceRecord, str] | None:
        """Let the original device collect its credential after WebUI approval.

        The raw credential is generated only at claim time, returned once, and
        never written to AstrBot storage. An unconfirmed code stays pending.
        """
        now = now or int(time.time())
        code = self._validate_code(code)
        async with self._devices_lock:
            pairings = await self._live_pairings(now)
            target = next((item for item in pairings if item.code == code), None)
            if target is None:
                raise ValueError("配对码不存在或已过期")
            if not target.confirmed:
                return None

            credential = secrets.token_urlsafe(32)
            record = DeviceRecord(
                device_id=target.device_id,
                display_name=target.display_name,
                credential_hash=self._hash_credential(credential),
                paired_at=now,
            )
            devices = await self._devices()
            devices = [item for item in devices if item.device_id != record.device_id]
            devices.append(record)
            await self._save_devices(devices)
            await self._save_pairings(
                [item for item in pairings if item.code != target.code],
            )
            return record, credential

    async def authenticate(self, device_id: str, credential: str) -> DeviceRecord | None:
        if not isinstance(credential, str) or not credential:
            return None
        async with self._devices_lock:
            devices = await self._devices()
            for device in devices:
                if device.device_id == device_id and secrets.compare_digest(
                    device.credential_hash,
                    self._hash_credential(credential),
                ):
                    device.last_seen_at = int(time.time())
                    await self._save_devices(devices)
                    return device
        return None

    async def revoke(self, device_id: str) -> bool:
        device_id = self._validate_identifier(device_id, "device_id")
        async with self._devices_lock:
            devices = await self._devices()
            remaining = [item for item in devices if item.device_id != device_id]
            if len(remaining) == len(devices):
                return False
            await self._save_devices(remaining)
            return True

    async def set_admin(self, device_id: str, is_admin: bool) -> DeviceRecord | None:
        """Set the AstrBot role granted to this authenticated physical device."""
        device_id = self._validate_identifier(device_id, "device_id")
        async with self._devices_lock:
            devices = await self._devices()
            target = next((item for item in devices if item.device_id == device_id), None)
            if target is None:
                return None
            target.is_admin = bool(is_admin)
            await self._save_devices(devices)
            return target

    async def rename(self, device_id: str, display_name: str) -> DeviceRecord | None:
        """Rename the human-facing sender label without changing device identity."""
        device_id = self._validate_identifier(device_id, "device_id")
        display_name = self._clean_display_name(display_name)
        async with self._devices_lock:
            devices = await self._devices()
            target = next((item for item in devices if item.device_id == device_id), None)
            if target is None:
                return None
            target.display_name = display_name
            await self._save_devices(devices)
            return target

    async def list_devices(self) -> list[DeviceRecord]:
        return await self._devices()

    async def _devices(self) -> list[DeviceRecord]:
        raw = await self._store.get_kv_data(self._DEVICES_KEY, [])
        return [DeviceRecord(**item) for item in raw if isinstance(item, dict)]

    async def _save_devices(self, devices: list[DeviceRecord]) -> None:
        await self._store.put_kv_data(
            self._DEVICES_KEY,
            [asdict(item) for item in devices],
        )

    async def _live_pairings(self, now: int) -> list[PairingRecord]:
        raw = await self._store.get_kv_data(self._PAIRINGS_KEY, [])
        return [
            PairingRecord(**item)
            for item in raw
            if isinstance(item, dict) and item.get("expires_at", 0) > now
        ]

    async def _save_pairings(self, pairings: list[PairingRecord]) -> None:
        await self._store.put_kv_data(
            self._PAIRINGS_KEY,
            [asdict(item) for item in pairings],
        )

    @staticmethod
    def _new_unique_code(pairings: list[PairingRecord]) -> str:
        existing = {item.code for item in pairings}
        for _ in range(100):
            code = f"{secrets.randbelow(1_000_000):06d}"
            if code not in existing:
                return code
        raise RuntimeError("无法分配唯一配对码")

    @staticmethod
    def _validate_identifier(value: str, field: str) -> str:
        if not isinstance(value, str) or not 1 <= len(value) <= 128:
            raise ValueError(f"{field} 无效")
        if any(ord(char) < 32 for char in value):
            raise ValueError(f"{field} 无效")
        return value

    @staticmethod
    def _clean_display_name(value: str) -> str:
        if not isinstance(value, str):
            return "Rokid Glasses"
        cleaned = " ".join(value.split())[:64]
        return cleaned or "Rokid Glasses"

    @staticmethod
    def _validate_code(value: str) -> str:
        if not isinstance(value, str) or len(value) != 6 or not value.isdigit():
            raise ValueError("配对码必须是六位数字")
        return value
