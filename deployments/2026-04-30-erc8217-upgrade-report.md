# Adapter8004 ERC-8217 Upgrade Report - 2026-04-30

> **Superseded:** `rewriteBindingMetadata` and `script/MigrateBindingMetadata.s.sol` were removed in
> `0.0.16`. The migration they describe was a prepared no-op for all three production proxies and was
> never required. See CHANGELOG.md. This report is kept as the dated record.


## Summary

UUPS upgrade aligning all three production proxies with [ERC-8217](https://github.com/ethereum/ERCs/commit/9159eb386cb437d2989d1c341a5955d78398705e). The new implementation writes `agent-binding` as exactly the 20-byte binding contract address (`abi.encodePacked(address(this))`) instead of the prior multi-field packed payload. Token standard, token contract, and token id are read only from `bindingOf(agentId)`.

This report supplements the original [2026-04-05-deployment-report.md](./2026-04-05-deployment-report.md) and the rollout plan [2026-04-30-erc8217-migration-plan.md](./2026-04-30-erc8217-migration-plan.md).

Owner / deployer (unchanged across all networks):

- `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`

Implementation source: commits [`ee2ceb0`](https://github.com/nxt3d/adapter/commit/ee2ceb0) and [`95e5a5c`](https://github.com/nxt3d/adapter/commit/95e5a5c) on `main`.

Pre-upgrade audit (executed 2026-04-30): zero `AgentBound` events on all three proxies. No metadata migration was required.

## Sepolia

- Chain ID: `11155111`
- IdentityRegistry: `0x8004A818BFB912233c491871b3d84c89A494BD9e` (unchanged)
- Adapter proxy: `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`
- Previous implementation (rolled out 2026-04-05): `0x5Ced539aE5Fe67183a2bA4E984F92D57dFB3bd49`
- New implementation: `0x03fC1F8D8485a36Ff2e0162B28499f18dC3AeDb4`
- New implementation deployment tx: `0x7ba4ea8b798130afc490abb90bf6cfa1174b3c58d1d82a819787deddb277d066`
- `upgradeToAndCall` tx: `0xcf3075deed33b047f4ab9872a5ffc8c6f3ccea0f444e58f29027e3379f3e134c`
- Block: `10764756`
- Broadcast artifact: [`broadcast/UpgradeAdapter.s.sol/11155111/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/UpgradeAdapter.s.sol/11155111/run-latest.json)
- Post-upgrade verification:
  - EIP-1967 implementation slot points to the new implementation
  - `identityRegistry()` unchanged
  - `owner()` unchanged
  - `bindingOf(0)` reverts with `0x7b65190b…` (unknown agent custom error) — interface live

## Base

- Chain ID: `8453`
- IdentityRegistry: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` (unchanged)
- Adapter proxy: `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`
- Previous implementation (rolled out 2026-04-05): `0x9DB9d78E1BB45604Fbfe30FaE123B152FA10de2d`
- New implementation: `0xcdf4C93Db79876928B155349a3B71962b2f94424`
- New implementation deployment tx: `0x098b60e3dd9862357f722a9783ea11234067bdce6362ee1eb3583e44a5d96f54`
- `upgradeToAndCall` tx: `0x6bac76a3a1611ff13417c47564b3b657c6680b82b3f4d35e067d6273dc802291`
- Block: `45398796`
- Broadcast artifact: [`broadcast/UpgradeAdapter.s.sol/8453/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/UpgradeAdapter.s.sol/8453/run-latest.json)
- Post-upgrade verification:
  - EIP-1967 implementation slot points to the new implementation
  - `identityRegistry()` unchanged
  - `owner()` unchanged
  - `bindingOf(0)` reverts with `0x7b65190b…` — interface live

## Ethereum Mainnet

- Chain ID: `1`
- IdentityRegistry: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` (unchanged)
- Adapter proxy: `0xde152AfB7db5373F34876E1499fbD893A82dD336`
- Previous implementation (rolled out 2026-04-05): `0xA54a604448A5Ab0AfFccdDa6228EC4F2ac12a586`
- New implementation: `0xcdeFFf9EaFCfa28be798D1c1B1c8D731087d1CE4`
- New implementation deployment tx: `0x9eb06e2e5897c26fb98d0414da7c28fb2c015c3e4b05eebb629be937624fa82f` (block `24995816`)
- `upgradeToAndCall` tx: `0x30aa6cbed8abcabca19fcfac94bd257559e7993b1f12b210e014613f16b4f953` (block `24995818`)
- Broadcast artifact: [`broadcast/UpgradeAdapter.s.sol/1/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/UpgradeAdapter.s.sol/1/run-latest.json)
- Post-upgrade verification:
  - EIP-1967 implementation slot points to the new implementation
  - `identityRegistry()` unchanged
  - `owner()` unchanged
  - `bindingOf(0)` reverts with `0x7b65190b…` — interface live

## Notes

Storage layout was identical before and after the upgrade (`forge inspect Adapter8004 storage-layout`). The struct moved from contract scope to interface scope but the slot order and field types were unchanged.

Off-chain readers that previously decoded the multi-field packed metadata must switch to:

1. Read `getMetadata(agentId, "agent-binding")` from the registry.
2. Treat the value as exactly 20 bytes — the binding contract address.
3. Call `bindingOf(agentId)` on that address to obtain `standard`, `tokenContract`, and `tokenId`.

If any agents are registered against these proxies in the future under a legacy implementation, the owner-only `rewriteBindingMetadata(uint256)` helper plus [`script/MigrateBindingMetadata.s.sol`](/Users/nxt3d/projects/adapter/script/MigrateBindingMetadata.s.sol) can rewrite their metadata to the canonical 20-byte form. Today, no such rewrite is required.

## Rollback Implementations

If rollback becomes necessary, each network can `upgradeToAndCall` back to its previous implementation. Storage layout is unchanged so rollback is safe.

| Network | Previous implementation |
| --- | --- |
| Sepolia | `0x5Ced539aE5Fe67183a2bA4E984F92D57dFB3bd49` |
| Base | `0x9DB9d78E1BB45604Fbfe30FaE123B152FA10de2d` |
| Mainnet | `0xA54a604448A5Ab0AfFccdDa6228EC4F2ac12a586` |
