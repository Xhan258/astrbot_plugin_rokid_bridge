from __future__ import annotations

import unittest

from services.device_registry import DeviceRegistry


class MemoryStore:
    def __init__(self) -> None:
        self.data = {}

    async def get_kv_data(self, key, default):
        return self.data.get(key, default)

    async def put_kv_data(self, key, value):
        self.data[key] = value


class DeviceRegistryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.registry = DeviceRegistry(MemoryStore(), pairing_ttl_seconds=60)

    async def test_pair_confirm_authenticate_and_revoke(self):
        pairing = await self.registry.request_pairing("glasses-1", "My Rokid", now=100)
        await self.registry.confirm_pairing(pairing.code, now=101)
        device, credential = await self.registry.claim_pairing(pairing.code, now=102)
        self.assertEqual(device.device_id, "glasses-1")
        self.assertIsNotNone(await self.registry.authenticate("glasses-1", credential))
        self.assertIsNone(await self.registry.authenticate("glasses-1", "wrong"))
        self.assertTrue(await self.registry.revoke("glasses-1"))
        self.assertIsNone(await self.registry.authenticate("glasses-1", credential))

    async def test_pairing_code_expires(self):
        pairing = await self.registry.request_pairing("glasses-1", "Rokid", now=100)
        with self.assertRaisesRegex(ValueError, "过期"):
            await self.registry.confirm_pairing(pairing.code, now=161)

    async def test_pairing_code_can_only_be_used_once(self):
        pairing = await self.registry.request_pairing("glasses-1", "Rokid", now=100)
        await self.registry.confirm_pairing(pairing.code, now=101)
        await self.registry.claim_pairing(pairing.code, now=102)
        with self.assertRaisesRegex(ValueError, "不存在或已过期"):
            await self.registry.claim_pairing(pairing.code, now=103)

    async def test_claim_waits_for_webui_confirmation(self):
        pairing = await self.registry.request_pairing("glasses-1", "Rokid", now=100)
        self.assertIsNone(await self.registry.claim_pairing(pairing.code, now=101))

    async def test_admin_flag_defaults_to_member_and_can_be_changed(self):
        pairing = await self.registry.request_pairing("glasses-1", "Rokid", now=100)
        await self.registry.confirm_pairing(pairing.code, now=101)
        device, _ = await self.registry.claim_pairing(pairing.code, now=102)
        self.assertFalse(device.is_admin)
        granted = await self.registry.set_admin("glasses-1", True)
        self.assertIsNotNone(granted)
        self.assertTrue(granted.is_admin)
        self.assertTrue((await self.registry.list_devices())[0].is_admin)
        revoked = await self.registry.set_admin("glasses-1", False)
        self.assertFalse(revoked.is_admin)

    async def test_authentication_preserves_latest_admin_and_name(self):
        pairing = await self.registry.request_pairing("glasses-1", "Rokid", now=100)
        await self.registry.confirm_pairing(pairing.code, now=101)
        _, credential = await self.registry.claim_pairing(pairing.code, now=102)
        await self.registry.set_admin("glasses-1", True)
        renamed = await self.registry.rename("glasses-1", "Alice Owner")
        self.assertEqual(renamed.display_name, "Alice Owner")
        authenticated = await self.registry.authenticate("glasses-1", credential)
        self.assertTrue(authenticated.is_admin)
        self.assertEqual(authenticated.display_name, "Alice Owner")
