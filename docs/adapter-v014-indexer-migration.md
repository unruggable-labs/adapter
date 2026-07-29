# Adapter8004 v0.0.14 indexer cutover

Record the upgrade block, exact `chainIdentifier()` bytes, and sample adapter/token
`interoperableAddress(address)` bytes per deployment. Before proposing an upgrade, verify the
implementation slot/version and scan the full proxy history for legacy
`PrimaryAgentSet`, `PrimaryAgentCleared`, and signed-audit topics. The required production result is
zero; stop rollout if any target fails.

At the cutover block:

- start separate full and counterfactual primary projections;
- subscribe to the new full `uint256` primary topics and the new counterfactual primary family;
- validate every counterfactual indexed hash as
  `keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId))`, with the dynamic
  adapter bytes carrying the full chain plus proxy address and `tokenContract` kept as a naked EVM
  address;
- retain old mixed events and bare-chain-id hashes as versioned legacy history.

Existing counterfactual event topic0 values do not change, but their indexed hash values do. Never
silently re-key historical logs into the new namespace. Optional old-to-new coordinate redirects
are discovery hints, not proof of a new claim. Do not seed either new pointer from frozen mixed
storage or legacy events; accounts re-attest. Record implementation addresses/code hashes, Safe
calldata, cutover/rollback blocks, old/new primary topics, post-upgrade reads, and sample hashes in
the deployment report. Rollback is operational containment only; pause new traffic and fix forward.
