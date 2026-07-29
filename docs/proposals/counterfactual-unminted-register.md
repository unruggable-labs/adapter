# Proposal: Counterfactual registration for unminted tokens

**Status:** proposal (product intent locked; implementation plan TBD)  
**Repo:** `/Users/nxt3d/projects/adapter`  
**Touches:** `Adapter8004` counterfactual surface (`IERC8004AdapterCounterfactual`, `src/Adapter8004.sol`)  
**Preserves:** existing controller-gated unsigned CF register and update family

## Problem

Adapter8004 can bind an external NFT to an ERC-8004 identity. Full `register` mints a second NFT in the ERC-8004 registry, which is unnecessary for many collections. Counterfactual registration solves that by emitting an indexed claim (`registrationHash` over the adapter proxy's full ERC-7930 Interoperable Address, the naked EVM token-contract address, and `tokenId`) with no registry write and no adapter SSTORE.

The remaining gap is **register-at-mint**.

Unsigned `counterfactualRegister` requires current binding control (`ownerOf` / balance / delegate). At mint time that fails: the token does not exist yet, or the lasting owner is not yet the controller. Earlier workarounds were all worse than the product wants:

1. **Signature-based counterfactual registration** — added EIP-712 payload, expiry, relayer, and replay complexity to every mint.
2. **Mint to the collection (or a staging address), register, then transfer to the buyer** — wastes gas and invents a temporary owner for no conceptual reason.
3. **Register after mint as a second user action** — breaks “agent identity exists when the NFT is born.”

Collections that mint their own NFTs already own the mint right for unissued token ids. The protocol should recognize that right for counterfactual registration, without signatures and without temporary ownership.

## Solution

While an external token id has **no owner**, the **token contract itself** may perform counterfactual registration for that id. Once the token has an owner, that path is closed and only the normal controller model applies.

### Authority window

| Token state | Who may CF-register / CF-update |
|---|---|
| Unminted (no owner) | `msg.sender == tokenContract` only |
| Minted (has owner) | Current controller only (existing `_requireBindingControl` / direct-holder rules). The token contract path is invalid. |

The collection may emit more than once while the window is open. That is fine: counterfactual state is event-sourced, and indexers already treat the **latest** event per `(tokenContract, tokenId)` as authoritative. There is **no** one-shot bit and **no** new SSTORE for this path.

After mint, the first real owner (or their delegate, where applicable) becomes the sole authority. Pre-mint claims from the collection do not outrank a later owner update.

### Ideal mint flow

In one transaction (or one atomic mint sequence):

```text
tokenContract → Adapter.counterfactualRegister...(tokenId, agentURI, metadata)
tokenContract → _mint(buyer, tokenId)
```

Ordering matters: register **while still unminted**, then mint. If mint runs first, the unminted window is closed and the collection must not use this path.

### What stays unchanged

- `registrationHash` domain:
  `keccak256(abi.encode(interoperableAddress(adapter), tokenContract, tokenId))`
- Emit-only semantics: no IdentityRegistry call, no adapter binding storage
- Latest-event-wins indexer rule
- Reserved metadata key rejection on CF payloads
- Signature-based counterfactual registration is removed; register-at-mint uses the direct
  collection call before mint
- Full on-chain `register` / `bindExisting` remain for collections that want a real ERC-8004 agent NFT

### Standard scope (intent)

This authority model is natural for **single-owner** standards where “no owner” is observable:

- ERC-721
- ERC-1155F
- ERC-6909F

Detection sketch: `ownerOf(tokenId)` reverts (or otherwise reports nonexistence) ⇒ unminted window open; a successful `ownerOf` ⇒ window closed.

Plain ERC-1155 / ERC-6909 do not have a universal global “no holder” proof. Keep those standards on
the existing positive-balance controller paths and do **not** invent a fake unminted window for them.

### Security intent

- **Griefing by strangers:** blocked, because only `tokenContract` may claim unminted ids.
- **Spam by the collection before mint:** allowed; the collection already controls minting. Last event wins. No protocol need to rate-limit.
- **Collection calling after mint:** must revert. Ownership has moved; the contract is no longer the authority.
- **Buyer / owner after mint:** uses today’s controller checks; can overwrite URI/metadata/wallet via existing CF update functions.
- **No temporary ownership:** never mint to the collection solely to satisfy `ownerOf` for registration.

## Non-goals

- Enforcing “exactly one” pre-mint registration on-chain
- Changing the ERC-8004 registry or minting an agent NFT for this path
- Removing post-mint controller CF updates
- Letting arbitrary EOAs register unminted ids
- Treating Tailscale / trusted infra as relevant (N/A; this is a local contract authority rule)

## Open points for the implementation plan

The plan should choose concrete answers for:

1. **API shape** — new entry point (e.g. `counterfactualRegisterUnminted`) vs extending unsigned `counterfactualRegister` with an unminted branch when `msg.sender == tokenContract`.
2. **Exact unminted detection** — try/catch on `ownerOf`, `extcodesize` + call success checks, and behavior for weird tokens that return `address(0)` instead of reverting.
3. **Whether CF *updates* (URI/metadata/wallet) share the same unminted window**, or only the register family does.
4. **Emitter field** — `emitter = tokenContract` vs `emitter = address(0)` vs a dedicated flag/version so indexers can mark “collection pre-mint claim.”
5. **Test matrix** — unminted happy path; after-mint collection call reverts; stranger unminted call reverts; owner overwrite after mint; same-tx register-then-mint; multi-emit before mint (last wins); F-standard coverage; 1155/6909 policy.
6. **Docs / README / CHANGELOG / interface comments** — register-at-mint guidance for collection authors.
7. **Upgrade path** — adapter is a proxy; plan the implementation bump and any interface addition carefully.

## Acceptance sketch

- A collection can CF-register token id `N` before mint with no owner signature and no staging transfer.
- After `_mint(buyer, N)`, the same collection call reverts; `buyer` (or delegate) can CF-update.
- No new adapter storage; no registry mint on this path.
- Existing unsigned CF and signed reverse-pointer tests remain green.

## History

Product discussion 2026-07-29: avoid mint-staging and avoid required mint signatures; treat “no owner” as a temporary authority window owned by `tokenContract`; allow multiple pre-mint emits; close the window on first owner.
