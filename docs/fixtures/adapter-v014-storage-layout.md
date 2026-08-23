# Adapter8004 v0.0.14 storage-layout evidence

Captured with `forge inspect Adapter8004 storageLayout`:

| Slot | Source name | Type | Policy |
|---:|---|---|---|
| 0 | `__deadRegistrySlot` | `uint256` | **DEAD. RESERVED FOREVER. NEVER REUSE.** |
| 1 | `_bindings` | `mapping(uint256 => Binding)` | unchanged |

**Regular storage is slot 1 alone.** Slot 0 held `identityRegistry` until `0.0.17` made
that field `immutable`, moving it out of proxy storage and into each implementation's runtime code.
All three live proxies have a real registry address written into slot 0 and it stays there as dead
bytes, so anything declared into that slot would read the address as its initial value.
`uint256 private __deadRegistrySlot` exists solely to hold the slot down.

Removing that placeholder is not a tidy-up; it is a corruption. Verified with
`forge inspect Adapter8004 storageLayout` rather than reasoned about: without it `_bindings` moves
to slot 0 and every existing binding would be read against the old registry address.
`testLayoutIsThreeSlotsAndSlotZeroStaysDead` fails if that ever happens.

## The rule for removing a slot

**Reserve a slot that holds live data. Do not reserve one that was merely declared in a build
nobody deployed.** A placeholder over a slot nothing has written is permanent dead space defending
against nothing, and it costs a slot forever.

Two mappings removed at `0.0.17` show both halves of the rule:

- `identityRegistry`, slot 0: **reserved**, because all three live proxies physically hold the old
  registry address there. Sliding `_bindings` onto it would read every existing binding against a
  dead word.
- `_walletAgentID` and `_walletUBI`, formerly slots 2 and 3, and `_primaryAgentNonces`, formerly
  slot 4: **not reserved**, because no deployed implementation ever declared any of them, so nothing
  has ever been written there. The deployed Mainnet/Base and Sepolia baselines declare only
  `identityRegistry` and `_bindings`.

The wallet-to-UBI reverse designation became emit-only at `0.0.17`, so it has no slot at all: the
contract verifies that the caller holds the authority to designate and records that fact in the log.
`testDirectUpgradeFromMainnetBaseLiveBaselinePreservesSlotsZeroAndOne` runs a designation against a
live-baseline proxy under `vm.record` and requires zero storage writes.

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
regular layout, populate slots 0 and 1, preserve the registry and binding across the upgrade, and
assert that a designation writes no storage at all. A separate Sepolia-baseline test proves delegate.xyz authorization survives the
upgrade.
