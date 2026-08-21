# Adapter8004 v0.0.14 storage-layout evidence

Captured with `forge inspect Adapter8004 storageLayout`:

| Slot | Source name | Type | Policy |
|---:|---|---|---|
| 0 | `identityRegistry` | `IERC8004IdentityRegistry` | unchanged |
| 1 | `_bindings` | `mapping(uint256 => Binding)` | unchanged |
| 2 | `_walletAgentID` | `mapping(address => uint256)` | appended full pointer |
| 3 | `_walletCounterfactualID` | `mapping(address => bytes32)` | appended CF pointer |

Regular storage ends at slot 3. A fourth mapping, `_primaryAgentNonces`, backed the signed
primary-agent surface and was removed at `0.0.17`; it was never written on any chain, because no
live implementation exposed a function that could reach it, so the slot is simply gone rather than
reserved or deprecated.

**How that was established, and how it was not.** Reading raw slot `0x04` proves nothing here, and
an earlier revision of this document wrongly cited it. A `mapping(address => uint256)` stores no
entry in its declaration slot: `_primaryAgentNonces[alice]` lives at
`keccak256(abi.encode(alice, uint256(4)))`, so slot `0x04` reads zero after any number of writes.
Calling `primaryAgentNonces(address)` and seeing it revert proves nothing either, because it tests
the implementation live at the moment of the call rather than every implementation the proxy has
ever pointed at.

What does prove it is that no implementation the proxy has ever pointed at contained a function
that writes the mapping. Verified on 2026-08-21 against all three live proxies: each resolved its
EIP-1967 implementation slot, and none of the three deployed runtimes contains selector
`0xeefb207c` (`setPrimaryAgentWithSig(address,uint256,uint256,bytes)`), `0xc77b008f`
(`clearPrimaryAgentWithSig(address,uint256,bytes)`) or `0xfd379e34` (`primaryAgentNonces(address)`).
Those were the only writers. Since the live runtimes predate the signed surface entirely, there was
never a code path that could reach a hashed slot-4 entry, so removing the declaration rather than
reserving a gap is safe for these three proxies. Anyone repeating this check must scan runtime
bytecode for the writing selectors across the proxy implementation history, not read slot `0x04`.

The actual deployed Mainnet/Base (`a20035c`) and Sepolia (`4647ddd`) baselines contain only slots
0 and 1. No initializer or heuristic migration is used: direct upgrades use empty
`upgradeToAndCall` data. The upgrade tests start from minimal implementations with that exact
regular layout, populate slots 0 and 1, prove slots 2 and 3 are empty before the upgrade, preserve
the registry and binding, verify new writes land at slots 2 and 3, and assert that nothing writes
past slot 3. A separate Sepolia-baseline test proves delegate.xyz authorization survives the
upgrade.
