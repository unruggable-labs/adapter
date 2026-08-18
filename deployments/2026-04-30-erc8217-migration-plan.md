# ERC-8217 Migration Plan

> **Superseded:** `rewriteBindingMetadata` and `script/MigrateBindingMetadata.s.sol` were removed in
> `0.0.16`. The migration they describe was a prepared no-op for all three production proxies and was
> never required. See CHANGELOG.md. This report is kept as the dated record.


Date: 2026-04-30

## Scope

Upgrade the deployed `Adapter8004` UUPS proxies to the ERC-8217-compliant implementation that stores `agent-binding` as exactly the 20-byte binding contract address, then rewrite any legacy `agent-binding` metadata rows if they exist.

Proxy targets:

- Sepolia: `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`
- Base: `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`
- Mainnet: `0xde152AfB7db5373F34876E1499fbD893A82dD336`

Resolved registries from live `identityRegistry()` calls on 2026-04-30:

- Sepolia: `0x8004A818BFB912233c491871b3d84c89A494BD9e`
- Base: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`
- Mainnet: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`

## Scripts

- Upgrade script: [script/UpgradeAdapter.s.sol](/Users/nxt3d/projects/adapter/script/UpgradeAdapter.s.sol:1)
- Migration script: [script/MigrateBindingMetadata.s.sol](/Users/nxt3d/projects/adapter/script/MigrateBindingMetadata.s.sol:1)

Expected env:

- `ADAPTER_PROXY_ADDRESS`
- `OWNER_PRIVATE_KEY`
- `AGENT_IDS` as decimal CSV, or `AGENT_IDS_FILE` containing decimal ids

## Pre-Upgrade Audit

Method used on 2026-04-30:

1. Read each proxy's `identityRegistry()` via JSON-RPC.
2. Enumerate `AgentBound(uint256,uint8,address,uint256,address)` logs from the proxy deployment block forward.
3. Use the resulting agent-id set as the rewrite candidate list.
4. For each candidate, classify `getMetadata(agentId, "agent-binding")` as `20 bytes` or `>20 bytes`.

Deployment blocks used:

- Sepolia proxy deployment tx `0xe81ae855a99c2b16642691409924098b996ec1e6a6e1da0b6d8378c0679d659d` at block `10597910`
- Base proxy deployment tx `0xe79d065dc2e83848e6c9a38e31f4fa3ec4062382cf86b62a21a47a0156aeabc6` at block `44347671`
- Mainnet proxy deployment tx `0xf4d34051b0bba198c8147c55bcc849517f5ba92a1b2ce25248c05d55b15bf519` at block `24821152`

Classification result as of 2026-04-30:

| Network | AgentBound ids found | 20-byte rows | Legacy rows `>20 bytes` |
| --- | ---: | ---: | ---: |
| Sepolia | 0 | 0 | 0 |
| Base | 0 | 0 | 0 |
| Mainnet | 0 | 0 | 0 |

Operational implication:

- There are no live adapter-registered agents to rewrite today.
- The upgrade is still required so future registrations emit the ERC-8217 payload.
- `MigrateBindingMetadata.s.sol` is presently a prepared no-op for all three production proxies.

## Upgrade Order

1. Sepolia
2. Base
3. Mainnet

Reason:

- Validate upgrade behavior on the testnet proxy first.
- Confirm proxy address remains the binding contract returned in metadata.
- Repeat on the lower-risk production chain before Mainnet.

## Procedure Per Network

1. Export `ADAPTER_PROXY_ADDRESS` for the target network.
2. Dry-run the upgrade script without broadcast.
3. Execute the UUPS upgrade:

```bash
forge script script/UpgradeAdapter.s.sol:UpgradeAdapterScript \
  --rpc-url <RPC_URL>
```

4. Verify post-upgrade:
   - `identityRegistry()` unchanged
   - `owner()` unchanged
   - implementation slot updated
   - `getMetadata(agentId, "agent-binding")` continues to decode as exactly 20 bytes for migrated or newly registered agents
5. If the pre-upgrade audit found agent ids, run:

```bash
forge script script/MigrateBindingMetadata.s.sol:MigrateBindingMetadataScript \
  --rpc-url <RPC_URL>
```

6. Re-classify all discovered ids and confirm every `agent-binding` row is exactly 20 bytes.

## Gas Estimate

Local Foundry test measurements from 2026-04-30:

- Upgrade path including implementation deployment and `upgradeToAndCall`: about `1.80M` gas
  Source: `testAdminCanUpgradeImplementation()` in [test/Adapter8004.t.sol](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:309)
- Per-agent metadata rewrite: about `237k` gas
  Source: `testRewriteBindingMetadataRewritesLegacyPayloadToTwentyBytes()` in [test/Adapter8004.t.sol](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:208)

Per-network estimate on 2026-04-30:

| Network | Upgrade gas | Rewrite gas |
| --- | ---: | ---: |
| Sepolia | about `1.80M` | `0` today |
| Base | about `1.80M` | `0` today |
| Mainnet | about `1.80M` | `0` today |

If agents are registered between audit time and execution time, add about `237k` gas per legacy row rewritten.

## Rollback Plan

Rollback is another UUPS upgrade back to the currently deployed implementation address for that network:

- Sepolia old impl: `0x5Ced539aE5Fe67183a2bA4E984F92D57dFB3bd49`
- Base old impl: `0x9DB9d78E1BB45604Fbfe30FaE123B152FA10de2d`
- Mainnet old impl: `0xA54a604448A5Ab0AfFccdDa6228EC4F2ac12a586`

Constraints:

- Rollback is storage-safe because the layout is unchanged.
- Rollback is cleanest before any metadata rewrites happen.
- If rewrites were already executed, reverting the implementation does not restore the old metadata payload shape; it only restores the old code.

Given the current audit result of zero registered ids, rollback remains straightforward on all three networks.

## Acceptance Criteria

- Upgrade succeeds on Sepolia, then Base, then Mainnet.
- `identityRegistry()` and `owner()` remain unchanged after each upgrade.
- The proxy, not the implementation, remains the binding contract address written by `abi.encodePacked(address(this))`.
- Off-chain readers no longer have any adapter ABI helper for this encoding; they must treat the metadata value itself as a 20-byte packed address and then call `bindingOf(agentId)` on that address.
- `_authorizeUpgrade` remains owner-gated.
- If any agent ids exist at execution time, every `agent-binding` row re-classifies to exactly 20 bytes after migration.
- No on-chain writes use the reserved `agent-binding` key except the adapter itself.
