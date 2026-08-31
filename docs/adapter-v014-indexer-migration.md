# Adapter8004 indexer cutover

Written for the `0.0.14` cutover and updated through `0.0.17`. The `0.0.14`-`0.0.17` source
versions are one cutover, not four: none of them is deployed, so an indexer moves from the live
pre-ERC-7930 scheme straight to the `0.0.17` shape in a single step.

Record the upgrade block, exact `chainIdentifier()` bytes, and sample adapter/token
`interoperableAddress(address)` bytes per deployment. Before proposing an upgrade, verify the
implementation slot/version and scan the full proxy history for stranded wallet-id state.

**Scan the legacy topics, not the new ones.** The state this gate exists to detect could only have
been written by an intermediate implementation, and that implementation emitted the `Primary*`
names. The wallet-to-agent-id surface those events belonged to was removed entirely at `0.0.17`, so
there is no current event to scan for at all and only the legacy topics can reveal stranded state.
Scan these four `topic0` values over full proxy history instead:

| Legacy event | `topic0` |
|---|---|
| `PrimaryAgentSet(address,uint256,address)` | `0x107facd48c6f216eb14d89f6825fd2edb53bc0de9f1739ad5930bd8e7406074f` |
| `PrimaryAgentCleared(address,address)` | `0xab6d48fb7b5d2183e12ec8f08a15cce507e5ab5147a4e919998616350f621907` |
| `PrimaryAgentSetWithSig(address,uint256,address,uint256)` | `0xff2aaef2ca17274fb71a88b3b6b8c70a37352433005dd6c33f994dfd11f4d2c1` |
| `PrimaryAgentClearedWithSig(address,address,uint256)` | `0x823fbecacc871fb9729292aa0b7c95f55a47ad02015577bb622c158c4f03328c` |

The `WithSig` pair matters most: those writers also incremented `_primaryAgentNonces`, whose
declaration was slot 4 and is removed rather than reserved at `0.0.17`, so a single historical
occurrence means a future append at slot 4 could collide with a live hashed entry. The required
production result is zero for all four; stop rollout if any target fails. Reading raw slot `0x04`
is not a substitute and does not prove the mapping is empty, for the reason set out in
[`adapter-v014-storage-layout.md`](./fixtures/adapter-v014-storage-layout.md).

At the cutover block:

- start a wallet UBID projection. There is no wallet agent id projection: that surface was removed at
  `0.0.17`, because an agent id is meaningful only inside the registry that issued it and a
  reverse-resolution surface keyed on one contradicted ERC-8217;
- subscribe to the `WalletUBIDSet` / `WalletUBIDCleared` family. These were named `Primary*` in an
  earlier build, then `WalletUBISet` / `WalletUBICleared`, before the acronym rename from UBI to
  UBID. `topic0` is the keccak of the full event signature, so it changed at every one of those
  renames: an indexer keying on the `WalletUBISet` topic0 must move to the `WalletUBIDSet` topic0
  (and likewise `WalletUBICleared` to `WalletUBIDCleared`). Take the new values from the
  regenerated hash fixture
  <!-- TODO: confirm the regenerated WalletUBIDSet / WalletUBIDCleared topic0 values land in
  adapter-counterfactual-hashes.md before publishing this cutover -->;
- validate every counterfactual indexed hash as
  `keccak256(abi.encode(adapterInteroperableAddress, uint8 standard, boundAddress, tokenId))`,
  with the dynamic adapter bytes carrying the full chain plus proxy address, `boundAddress` kept as a
  naked EVM address, and `standard` the `TokenStandard` enum value. There is no trailing discriminator
  word; a preimage carrying one is an earlier scheme, tabulated as superseded in the hash fixture;
- key rows by that hash alone. One `(boundAddress, tokenId)` under two standards is two identities
  from this cutover forward, so a projection that collapses by coordinate merges histories belonging
  to different claimants;
- retain old mixed events and bare-chain-id hashes as versioned legacy history.

Counterfactual event topic0 values change as well as their indexed hash values. Every counterfactual
event gained a non-indexed `bytes32 extraData` at `0.0.15`; at `0.0.17` the five update events and
`WalletUBIDSet` each gained a non-indexed `uint8 standard`, and then `extraData` was
dropped from all seven. Every counterfactual topic0 therefore differs from `0.0.15`, including
`CounterfactualAgentRegistered`, so subscriptions must be rewritten rather than reused. The current
values are tabulated in
[`adapter-counterfactual-hashes.md`](./fixtures/adapter-counterfactual-hashes.md). Never silently
re-key historical logs into the new namespace. Optional old-to-new coordinate redirects
are discovery hints, not proof of a new claim. Do not seed either new pointer from frozen mixed
storage or legacy events; accounts re-attest. Record implementation addresses/code hashes, Safe
calldata, cutover/rollback blocks, old and new wallet-id topics, post-upgrade reads, and sample hashes in
the deployment report. Rollback is operational containment only; pause new traffic and fix forward.
