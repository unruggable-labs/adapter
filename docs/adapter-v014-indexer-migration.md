# Adapter8004 indexer cutover

Written for the `0.0.14` cutover and updated through `0.0.17`. The `0.0.14`-`0.0.17` source
versions are one cutover, not four: none of them is deployed, so an indexer moves from the live
pre-ERC-7930 scheme straight to the `0.0.17` shape in a single step.

Record the upgrade block, exact `chainIdentifier()` bytes, and sample adapter/token
`interoperableAddress(address)` bytes per deployment. Before proposing an upgrade, verify the
implementation slot/version and scan the full proxy history for legacy
`WalletAgentIDSet`, `WalletAgentIDCleared`, and signed-audit topics. The required production result is
zero; stop rollout if any target fails.

At the cutover block:

- start separate wallet agent id and wallet counterfactual id projections;
- subscribe to the `WalletAgentIDSet` / `WalletAgentIDCleared` topics and the `WalletCounterfactualIDSet` / `WalletCounterfactualIDCleared` family. These were named `Primary*` in an earlier build and every one of those topic0 values changed with the rename;
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
`WalletCounterfactualIDSet` each gained a non-indexed `uint8 standard`, and then `extraData` was
dropped from all eight. Every counterfactual topic0 therefore differs from `0.0.15`, including
`CounterfactualAgentRegistered`, so subscriptions must be rewritten rather than reused. The current
values are tabulated in
[`adapter-counterfactual-hashes.md`](./fixtures/adapter-counterfactual-hashes.md). Never silently
re-key historical logs into the new namespace. Optional old-to-new coordinate redirects
are discovery hints, not proof of a new claim. Do not seed either new pointer from frozen mixed
storage or legacy events; accounts re-attest. Record implementation addresses/code hashes, Safe
calldata, cutover/rollback blocks, old and new wallet-id topics, post-upgrade reads, and sample hashes in
the deployment report. Rollback is operational containment only; pause new traffic and fix forward.
