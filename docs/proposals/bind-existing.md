# Adapter8004 `bindExisting` Proposal

## Summary

Add a design-only `bindExisting` entry point that lets the owner of an already-minted ERC-8004 `agentId` transfer that identity into `Adapter8004` management and bind it to an external ERC-721, ERC-1155, or ERC-6909 token. The flow uses the PM-selected two-transaction approval model:

1. The agent owner calls `IdentityRegistry.approve(adapter, agentId)` or `setApprovalForAll(adapter, true)`.
2. The same owner calls `Adapter8004.bindExisting(...)`.

`bindExisting` should preserve the existing `agentURI` and all non-binding metadata already present on the ERC-8004 identity. The binding operation becomes the authoritative moment for the reserved `agent-binding` metadata key, so the adapter overwrites that key unconditionally after taking registry ownership.

## Final Function Signature

```solidity
function bindExisting(
    uint256 agentId,
    TokenStandard standard,
    address tokenContract,
    uint256 tokenId
) external nonReentrant;
```

The function should be added to the adapter registration interface or to a small companion interface for post-mint binding, depending on the implementation preference for interface versioning. My recommendation is to add it to `IERC8004AdapterRegistration`, because it is another on-chain registration/binding entry point and emits the existing `AgentBound` event.

## Helper Additions

Add errors:

```solidity
error AlreadyBound(uint256 agentId);
error NotAgentOwner(uint256 agentId, address owner);
error AgentTransferNotApproved(uint256 agentId);
```

Optional helper:

```solidity
function _requireAgentTransferApproval(uint256 agentId, address owner) internal view;
```

The helper should accept either per-token approval or operator approval:

```solidity
IERC721 registry721 = IERC721(address(identityRegistry));
if (
    registry721.getApproved(agentId) != address(this)
        && !registry721.isApprovedForAll(owner, address(this))
) {
    revert AgentTransferNotApproved(agentId);
}
```

The current `IERC8004IdentityRegistry` interface does not expose ERC-721 transfer/approval methods even though the registry is ERC-721-compatible. Implementation can either cast `address(identityRegistry)` to `IERC721` at call sites or make the registry interface extend the ERC-721 surface. I recommend casting to `IERC721` locally to keep the ERC-8004 metadata interface narrow.

## Step-by-Step Flow

1. Reject `tokenContract == address(0)` with existing `InvalidTokenContract()`.

   This matches the current `register` and counterfactual revert taxonomy.

2. Reject an already-bound `agentId`:

   ```solidity
   if (_bindings[agentId].tokenContract != address(0)) revert AlreadyBound(agentId);
   ```

   This prevents overwriting adapter-managed bindings and keeps `bindingOf(agentId)` immutable after binding.

3. Read `owner = identityRegistry.ownerOf(agentId)` and require `owner == msg.sender`.

   This is intentionally stricter than registry approval. A delegated external-token controller cannot pull someone else's ERC-8004 identity into the adapter just because the adapter was approved.

4. Require external-token binding control:

   ```solidity
   _requireBindingControl(standard, tokenContract, tokenId, msg.sender);
   ```

   This preserves the adapter's existing authority model: direct ownership for ERC-721/1155/6909, plus delegate.xyz v2 authorization for ERC-721.

5. Check ERC-721 registry transfer approval before attempting the transfer.

   Revert with `AgentTransferNotApproved(agentId)` if the adapter is neither approved for `agentId` nor approved-for-all by the owner. This produces a clear adapter error instead of surfacing a generic ERC-721 transfer failure.

6. Transfer registry ownership into the adapter:

   ```solidity
   IERC721(address(identityRegistry)).transferFrom(msg.sender, address(this), agentId);
   ```

   This is deliberately before any adapter storage or registry metadata writes. If transfer authorization or registry transfer hooks fail, the transaction reverts with no adapter state changes.

7. Persist the adapter binding:

   ```solidity
   _bindings[agentId] = Binding({standard: standard, tokenContract: tokenContract, tokenId: tokenId});
   ```

8. Overwrite canonical binding metadata:

   ```solidity
   identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));
   ```

   This matches `register` and ERC-8217 verifier expectations. It should overwrite any pre-existing value, including arbitrary user data or a value pointing at another adapter.

9. Clear the default agent wallet:

   ```solidity
   identityRegistry.unsetAgentWallet(agentId);
   ```

   This matches `register` behavior and avoids leaving a wallet controlled by the pre-bind registry owner while the adapter now owns the identity NFT.

10. Emit the existing event:

    ```solidity
    emit AgentBound(agentId, standard, tokenContract, tokenId, msg.sender);
    ```

    Reuse the existing event so indexers do not need a separate binding event family.

## Order-of-Operations Rationale

All validation happens before state mutation. The first external state-changing call is `transferFrom`, and it happens before `_bindings` is written and before metadata or wallet writes. The adapter only writes its own binding storage after the ERC-8004 identity is owned by the adapter, so subsequent `setMetadata` and `unsetAgentWallet` calls should satisfy the registry's owner/approval checks.

If `transferFrom`, `setMetadata`, or `unsetAgentWallet` reverts, the EVM reverts the entire transaction, including external contract state changes from earlier calls in the same transaction. There is no partial binding, leaked metadata write, or stuck registry transfer. `nonReentrant` should remain on the entry point because the flow makes several external calls before and after adapter state mutation.

## Revert Taxonomy

Existing errors reused:

- `InvalidTokenContract()` when `tokenContract == address(0)`.
- `NotController(msg.sender, type(uint256).max)` when the caller does not control the external token under `_requireBindingControl`.

New errors:

- `AlreadyBound(uint256 agentId)` when `_bindings[agentId].tokenContract != address(0)`.
- `NotAgentOwner(uint256 agentId, address owner)` when `identityRegistry.ownerOf(agentId) != msg.sender`.
- `AgentTransferNotApproved(uint256 agentId)` when the adapter lacks per-token or operator approval to transfer the ERC-8004 identity.

I would let `identityRegistry.ownerOf(agentId)` bubble its native unknown-token revert for nonexistent `agentId`s instead of wrapping it in `UnknownAgent`. `UnknownAgent` currently means "not known to this adapter," while `bindExisting` is explicitly dealing with identities not yet known to the adapter.

## Test Plan

Add focused tests in `test/Adapter8004.t.sol`:

- Happy path: user mints an ERC-8004 identity directly, writes an agent URI and non-binding metadata, approves the adapter, calls `bindExisting`, then verify registry owner is the adapter, URI is unchanged, non-binding metadata is unchanged, `agent-binding` is `abi.encodePacked(address(adapter))`, wallet is cleared, `bindingOf(agentId)` returns the selected token, and `AgentBound` emits with `registeredBy == msg.sender`.
- Per-token approval path succeeds with `approve(adapter, agentId)`.
- Operator approval path succeeds with `setApprovalForAll(adapter, true)`.
- Zero `tokenContract` reverts with `InvalidTokenContract()`.
- Already-bound `agentId` reverts with `AlreadyBound(agentId)`.
- Caller who controls the external token but does not own the ERC-8004 identity reverts with `NotAgentOwner(agentId, owner)`.
- Caller who owns the ERC-8004 identity but does not control the external token reverts with `NotController(caller, type(uint256).max)`.
- Missing registry approval reverts with `AgentTransferNotApproved(agentId)` before `transferFrom`.
- Pre-existing `BINDING_METADATA_KEY` value is overwritten with the adapter address.
- Existing `agentURI` is preserved; caller can update it after binding through `setAgentURI` if they still control the external token.
- Existing non-binding metadata keys are preserved and can be updated after binding through `setMetadata`.
- Agent wallet is cleared even if the direct registry mint initially set it to the user.
- Post-bind controller follows the external token, matching existing `register` behavior.
- ERC-1155 and ERC-6909 bind paths succeed for current positive-balance holders, using the same direct-control checks as `register`.
- ERC-721 delegate.xyz path, if covered in security tests, succeeds only when the caller is also the ERC-8004 identity owner; delegation alone is not enough.
- Reentrancy/security regression: preserve existing `nonReentrant` assumptions around external calls.

Existing tests do not appear to encode an invariant that every bound agent was minted through the adapter. They mainly assert that `register`-created agents are owned by the adapter and have adapter-written binding metadata. `bindExisting` should satisfy the same post-bind invariants, so the new tests should add coverage without breaking the current ones.

## Counterfactual Interaction

The counterfactual functions are independent from `bindExisting`. They do not know or store an ERC-8004 `agentId`, do not call `identityRegistry`, and do not write `_bindings`. Their `registrationHash` domain is:

```solidity
keccak256(abi.encode(block.chainid, address(this), tokenContract, tokenId))
```

That domain is keyed by adapter and external token coordinates, not by `(IdentityRegistry, agentId)`. A caller can counterfactually register a token first and later bind an existing on-chain `agentId` to that same token. There is no on-chain storage conflict. Indexers should treat counterfactual events as soft-state claims and the later `AgentBound(agentId, ...)` as the on-chain binding record for the specific ERC-8004 identity.

This also means `bindExisting` should not add reverse uniqueness on `(tokenContract, tokenId)` unless the product wants to change the existing model. Current `register` tests explicitly allow the same external token to register multiple ERC-8004 agents, and `bindExisting` should follow that precedent.

## Answers to PM Open Questions

### A. Does `register` set `agentURI` through `identityRegistry.register(agentURI)`?

Yes. The no-metadata overload calls `identityRegistry.register(agentURI)`, and the metadata overload calls `identityRegistry.register(agentURI, metadata)`. After minting, the only adapter-specific initialization is `_bindings[agentId]`, canonical `agent-binding` metadata, and `unsetAgentWallet(agentId)`. `bindExisting` can skip URI initialization without leaving the adapter inconsistent as long as it performs those three post-bind steps.

### B. What if the caller previously wrote `BINDING_METADATA_KEY` themselves?

Overwrite it unconditionally. Before binding, any value at `agent-binding` is not authoritative for this adapter; after binding, ERC-8217 discovery should point to `address(this)` and `bindingOf(agentId)`.

### C. Should `bindExisting` accept an optional updated `agentURI`?

No. Keep `bindExisting` minimal and strictly preserve the existing URI. If the caller wants to refresh the URI, they can call `setAgentURI(agentId, newURI)` after binding, gated by the same external-token control model as all other adapter-managed updates.

### D. Are there existing tests that collide?

I do not see a conflicting invariant. The current tests assert invariants for adapter-minted `register` results and explicitly allow the same external token to register multiple agents; `bindExisting` should add a second creation path that reaches the same post-bind invariants without changing the existing register behavior.

### E. Any gas/accounting concern about `transferFrom` reverting after auth/state changes?

No if the implementation orders operations as proposed: perform validation first, call `transferFrom` before any adapter storage writes or metadata writes, and rely on transaction atomicity for later registry call failures. There is no partial state or leaked metadata if any external call reverts.

## Ambiguities Before Implementation

- Confirm whether `AgentTransferNotApproved(agentId)` should also include the owner and adapter addresses for richer debugging, or stay compact.
- Confirm whether adding `bindExisting` to `IERC8004AdapterRegistration` is acceptable, or whether the team wants a new interface to avoid changing the existing registration interface.
- Confirm that preserving the current "same external token may bind multiple agentIds" behavior is intended for `bindExisting`.
