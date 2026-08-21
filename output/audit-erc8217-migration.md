# Adapter8004 ERC-8217 Migration Audit

Date: 2026-04-30

> **Superseded in part.** This is a dated audit record and is not updated. The owner-only
> `rewriteBindingMetadata(uint256)` helper described below, and the upgrade/migration scripts that
> accompanied it, have since been removed from the contract and the repository. Do not plan a
> metadata rewrite from this document; the entry point it names does not resolve. The `agent-binding`
> format findings and the live-state readings remain accurate as of their date.

## Executive Summary

The working tree now aligns `Adapter8004` with ERC-8217's simplified `agent-binding` metadata format: the registry stores only the 20-byte binding contract address, while the canonical token binding remains in `bindingOf(agentId)`. The contract now also exposes an owner-only `rewriteBindingMetadata(uint256)` helper for post-upgrade repair of legacy rows and includes upgrade/migration scripts for UUPS rollout.

Live-state audit result on 2026-04-30:

- Mainnet proxy `0xde152AfB7db5373F34876E1499fbD893A82dD336`: `0` `AgentBound` events since deployment
- Base proxy `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`: `0` `AgentBound` events since deployment
- Sepolia proxy `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`: `0` `AgentBound` events since deployment

That means the migration helper is necessary for correctness and future-proofing, but there are no live rows to rewrite as of this audit.

## Spec Compliance

Reference spec: ERC-8217 commit `9159eb386cb437d2989d1c341a5955d78398705e`

| ERC-8217 requirement | Status | Source |
| --- | --- | --- |
| Minimal `IERCAgentBindings` interface MUST be exposed | Satisfied | [src/interfaces/IERCAgentBindings.sol](/Users/nxt3d/projects/adapter/src/interfaces/IERCAgentBindings.sol:4), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:14), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:179) |
| `agent-binding` metadata key MUST be used | Satisfied | [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:15), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:99), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:160) |
| Metadata value MUST be exactly `abi.encodePacked(bindingContract)` | Satisfied | [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:146), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:147) |
| Binding address MUST match the contract serving `bindingOf(agentId)` | Satisfied | [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:99), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:160), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:179) |
| `tokenStandard`, `tokenContract`, `tokenId` MUST come from `bindingOf` only | Satisfied | [src/interfaces/IERCAgentBindings.sol](/Users/nxt3d/projects/adapter/src/interfaces/IERCAgentBindings.sol:11), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:38), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:179) |
| `agent-binding` MUST be reserved against untrusted overwrite | Satisfied | [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:116), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:121), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:129), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:282) |
| Client verification MUST treat binding as unverified if metadata decode or `bindingOf` fails | Partially implementable; adapter supports it | Contract provides deterministic 20-byte metadata and reverting `bindingOf` for unknown ids at [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:179); client-side failure handling is off-chain behavior |
| Clients SHOULD assess the binding contract's security and upgrade risk | Not enforceable on-chain; documented risk | UUPS owner gate at [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:210) is the relevant code surface |

## Security Review

### Reserved-key handling

- `register()` rejects user-supplied metadata that targets `agent-binding` before the registry call: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:89)
- `setMetadata()` rejects direct reserved-key writes: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:120)
- `setMetadataBatch()` rejects any reserved-key entry in the batch: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:133), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:282)

Risk judgment:

- Low. The canonical key remains adapter-controlled both at registration time and during migration.

### Controller checks

- Registration requires current token control before an agent can be created: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:86), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:231)
- All user-write paths remain controller-gated: `setAgentURI`, `setMetadata`, `setMetadataBatch`, `setAgentWallet`, `unsetAgentWallet` at [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:108), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:116), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:129), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:163), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:171)
- Controller resolution still follows ERC-721 ownership and ERC-1155 / ERC-6909 balances: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:241), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:256)

Risk judgment:

- Low. The ERC-8217 change does not alter authorization semantics.

### Owner-gated migration helper

- `rewriteBindingMetadata(uint256)` is owner-only and refuses unknown agents: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:151)
- The helper rewrites from `_bindings` plus `address(this)` and does not trust current metadata contents: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:154), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:160)

Risk judgment:

- Good design. The helper cannot be abused by a token controller and is safe to run after upgrade because it derives the canonical value from proxy state, not from legacy bytes.

### Upgrade authorization

- UUPS authorization stays `onlyOwner`: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:210)
- The upgrade script only calls `upgradeToAndCall(newImpl, bytes(""))`, with no reinitializer: [script/UpgradeAdapter.s.sol](/Users/nxt3d/projects/adapter/script/UpgradeAdapter.s.sol:8)

Risk judgment:

- Low, with the standard UUPS caveat that trust rests on the proxy owner key.

## Storage Layout

`forge inspect Adapter8004 storage-layout` before and after shows no slot shift.

Old implementation at `HEAD`:

- `identityRegistry` at slot `0`
- `_bindings` at slot `1` as `mapping(uint256 => Adapter8004.Binding)`

New implementation:

- `identityRegistry` at slot `0`
- `_bindings` at slot `1` as `mapping(uint256 => IERCAgentBindings.Binding)`

Assessment:

- Safe. The struct fields are unchanged in order and type; only the type name moved from contract scope to interface scope.
- No new storage variables were added for the rewrite helper or scripts.

## Test Coverage

Executed on 2026-04-30:

- `forge build`
- `forge test -vvv`
- Result: `91` tests passed, `0` failed

Key tests and what they prove:

| Test | Coverage |
| --- | --- |
| [testEncodeBindingMetadataIsTwentyByteAddress](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:176) | ERC-8217 20-byte payload requirement |
| [testBindingVerifierRoundTripUsesStoredBindingContract](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:183) | Verifier flow: metadata address -> `bindingOf(agentId)` |
| [testAdapterImplementsIERCAgentBindingsInterface](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:197) | Contract is callable as `IERCAgentBindings` |
| [testRewriteBindingMetadataRewritesLegacyPayloadToTwentyBytes](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:208) | Legacy metadata can be rewritten to canonical ERC-8217 bytes |
| [testRegisterRejectsReservedBindingMetadataKey](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:228) | Reserved key protection on registration |
| [testSetMetadataRejectsReservedBindingMetadataKey](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:242) | Reserved key protection on single writes |
| [testSetMetadataBatchRejectsReservedBindingMetadataKey](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:251) | Reserved key protection on batch writes |
| [test721ControlFollowsTokenTransfer](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:98) | ERC-721 control follows current ownership |
| [test1155ControlIsAnyCurrentHolder](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:114) | ERC-1155 control follows balances |
| [test6909ControlIsAnyCurrentHolder](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:126) | ERC-6909 control follows balances |
| [testRewriteBindingMetadataIsOwnerOnly](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:256) | Migration helper cannot be called by a token controller |
| [testBindingOfHappyPath](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:268) | Canonical binding struct returned unchanged |
| [testBindingOfUnknownAgentReverts](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:276) | Unknown ids are unverified by construction |
| [testIsControllerTracksTokenOwnership](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:285) | Read-path controller logic remains correct |
| [testIsController1155TracksBalance](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:296) | Read-path ERC-1155 controller logic remains correct |
| [testIsController6909TracksBalance](/Users/nxt3d/projects/adapter/test/security/Adapter8004.security.t.sol:303) | Read-path ERC-6909 controller logic remains correct |
| [testFuzzBindingImmutableAcrossAllWrites](/Users/nxt3d/projects/adapter/test/security/Adapter8004.invariants.t.sol:63) | `_bindings` state is not mutated by unrelated writes |
| [testFuzzCanonicalBindingMetadataMatchesEncoder](/Users/nxt3d/projects/adapter/test/security/Adapter8004.invariants.t.sol:100) | Stored metadata always matches the inline `abi.encodePacked(address(adapter))` form |
| [testFuzzInitialWalletClearedAfterRegister](/Users/nxt3d/projects/adapter/test/security/Adapter8004.invariants.t.sol:45) | Existing wallet-clearing behavior remains intact |
| [testRegisterRevertsCleanlyWhenRegistryFails](/Users/nxt3d/projects/adapter/test/security/Adapter8004.invariants.t.sol:159) | Registration remains atomic under downstream failure |
| [testAdminCanUpgradeImplementation](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:309) | UUPS upgrade path still works |
| [testNonAdminCannotUpgradeImplementation](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol:320) | Upgrade path remains owner-gated |

## UUPS-Specific Risks

### Proxy address must remain the binding contract

This implementation writes `abi.encodePacked(address(this))` during both registration and rewrite: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:99), [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:154)

Under UUPS delegatecall, `address(this)` is the proxy address, not the implementation address. That is correct and required by ERC-8217 because clients later call `bindingOf(agentId)` on the stored address. If this code were ever executed against the implementation directly, metadata would point at the wrong address, but production usage is proxied and tests instantiate the proxy path.

### `_authorizeUpgrade`

Upgrade auth remains a single `onlyOwner` gate: [src/Adapter8004.sol](/Users/nxt3d/projects/adapter/src/Adapter8004.sol:210)

Residual risk:

- The owner key remains a high-trust actor and can change binding behavior in future upgrades.
- ERC-8217 explicitly puts trust on the binding contract, so clients should treat upgradeability as part of the trust model.

## Off-Chain Reader Impact

Consumers that need to switch:

- Any client that decodes `agent-binding` as `address + standard + tokenContract + tokenIdLength + compactTokenId`
- Any client that relied on the removed selector `encodeBindingMetadata(address,uint8,address,uint256)`
- Any off-chain caller that relied on the now-removed trivial helper `encodeBindingMetadata(address)`
- Any indexer or verifier that treated the metadata payload itself as the canonical token binding

Consumers should now:

1. Read `getMetadata(agentId, "agent-binding")`
2. Require length `== 20`
3. Decode only the binding contract address
4. Call `bindingOf(agentId)` on that address for `standard`, `tokenContract`, and `tokenId`

In-repo note:

- No off-chain consumer inside the `adapter` repository needed code changes for this shift.
- The impact is downstream and external to this repo.

## Migration Scripts Review

- [script/UpgradeAdapter.s.sol](/Users/nxt3d/projects/adapter/script/UpgradeAdapter.s.sol:7) deploys a new implementation and immediately calls `upgradeToAndCall(newImpl, bytes(""))`
- [script/MigrateBindingMetadata.s.sol](/Users/nxt3d/projects/adapter/script/MigrateBindingMetadata.s.sol:7) loops over supplied ids and invokes `rewriteBindingMetadata`
- The migration script accepts either `AGENT_IDS` or `AGENT_IDS_FILE`, parsing decimal ids only: [script/MigrateBindingMetadata.s.sol](/Users/nxt3d/projects/adapter/script/MigrateBindingMetadata.s.sol:23)

Risk judgment:

- Acceptable for rollout. No broadcast was executed during this audit.

## Findings

No blocking correctness or security findings remain in the proposed change set.

Residual risks:

- Downstream decoders must stop interpreting legacy multi-field metadata.
- Because the adapter is UUPS-upgradeable, integrators should treat owner key control as part of the trust model.
- The live migration set is empty today, but rollout must re-run the pre-upgrade event audit immediately before broadcasting in case agents are registered in the meantime.
