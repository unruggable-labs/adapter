# Security Review: Adapter8004 delegate.xyz v2 ERC-721 Support

**Reviewed by:** CSO (Chief Security Officer), security-adapter stack playbook
**Date:** 2026-05-16
**Change:** delegate.xyz v2 ERC-721 delegate authorization for `Adapter8004.sol` (UUPS upgrade)
**Verdict:** GO — safe to commit and proceed toward the UUPS upgrade. 0 Critical, 0 High.

> **Superseded in part.** This review records what was verified on 2026-05-16 and is not updated.
> One item below, `rewriteBindingMetadata` correctly remains `onlyOwner`, refers to a function that
> has since been removed from the contract, so it no longer names anything checkable. The delegate.xyz
> findings and verdict stand for the surface that remains.

## Verification performed (all clean)

- `forge build` — clean (cosmetic lint warnings only).
- `forge fmt --check` — clean.
- `forge test` — 162 tests pass, 0 fail (18 new delegate tests included).
- `forge inspect Adapter8004 storage-layout` — 2 slots (`identityRegistry` slot 0,
  `_bindings` slot 1), byte-identical to the recorded baseline
  (SHA `61f0912c...`). The two new values are `public constant` — bytecode, not
  storage. UUPS upgrade is storage-safe.
- `DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493` — EIP-55 valid,
  canonical delegate.xyz v2 deployment.
- `DELEGATE_RIGHTS = keccak256("adapter8004.manage")` — confirmed.

## Findings

### DEL-01 — MEDIUM — Counterfactual hash-collision reachable by a delegate
`_registrationHash` (`Adapter8004.sol:588`) excludes `TokenStandard` (documented as
intentional at `:584-587`). Previously only a direct token owner could emit
counterfactual events; a delegate can now too. On a hybrid contract implementing
both ERC-721 and ERC-1155 at the same `tokenId`, a delegate can emit counterfactual
events that hash-collide with the ERC-1155 holder's claims. Does not bypass on-chain
authorization or registry state — affects only the off-chain event stream consumed
as soft-state. The change does not create the collision (pre-existing accepted
design quirk); it widens *who* can trigger it from "owner only" to "owner or
delegate".

**Disposition:** Non-blocking. Indexer-spec item, not a contract change. Folded into
the existing CF-01 backlog; route to indexer-security on the next idx-indexer review.
See Reviewer Note 2 below for clarification.

### DEL-02 — LOW — Empty/full-rights widening is intended but under-tested
Passing the nonzero `DELEGATE_RIGHTS` to `checkDelegateForERC721` is correct and
intended: delegate.xyz v2 also matches empty/full delegations. Confirmed it does not
widen authority beyond what the cold wallet itself granted. Residual concern is
UX-only: a broad `delegateAll` for an unrelated dApp also grants Adapter8004 control.

**Disposition:** Non-blocking, accepted design. Optionally add a boundary test
(`delegateContract` for an unrelated contract must not authorize) and a docs note.

### DEL-03 — LOW — No `__gap` / storage-gap reservation
Pre-existing (carried forward as CF-03). Not introduced by this change, which adds
zero storage.

**Disposition:** Non-blocking. Adapter8004 is the leaf/most-derived contract — a
`__gap` only protects child contracts from a growing parent, and there is no child.
The OpenZeppelin Upgradeable 5.6.1 bases (`OwnableUpgradeable`, `UUPSUpgradeable`,
`Initializable`) use ERC-7201 namespaced storage, so they cannot collide with the
regular layout regardless. Future storage may simply be appended after `_bindings`
(append-only: never insert, reorder, or retype existing variables). No action needed.

### DEL-04 — INFORMATIONAL — `updatedBy`/`registeredBy` is the delegate, not the owner
When a delegate acts, emitted events carry `msg.sender` (the hot wallet) as the
actor. Correct. Indexers should treat `updatedBy` as the actor; resolve `ownerOf`
at the block if owner attribution is needed.

### DEL-05 — INFORMATIONAL — Registry trust assumption
`_isERC721Delegate` fails closed on `code.length == 0`. It cannot distinguish the
real registry from an impostor with code at the same address, but this is not
exploitable: the address is a CREATE2-deterministic constant an attacker cannot
occupy, and is not owner-mutable (deliberate — keeps authorization off the owner's
mutable policy surface).

### DEL-06 — INFORMATIONAL — Pre-existing cosmetic lint warnings
`mixed-case-function` (`_isERC721Delegate`), `asm-keccak256` (`_registrationHash`).
No security impact.

## Checked and found clean

Authorization short-circuit (`account == owner`); delegate authority scoped to the
current `ownerOf` and the specific token; stale-delegation-invalidation after
transfer; reentrancy (mutating functions `nonReentrant`, registry call is `view`);
return-value handling; gas griefing (bounded `staticcall`); fail-closed logic;
`rights` semantics not widening authority beyond the grant; ERC-1155/ERC-6909 paths
byte-for-byte unchanged; the two `_hasBindingControl` overloads provably consistent;
counterfactual path; `rewriteBindingMetadata` correctly remains `onlyOwner`;
`isController` delegate lifecycle; storage layout / UUPS upgrade safety;
`_authorizeUpgrade` unchanged; the minimal `IDelegateRegistry` interface; the
18-test delegate suite.

## Reviewer Notes / Clarifications

**Note 1 — `_hasBindingControl` overload kept as-is.** The 4-arg overload
`_hasBindingControl(standard, tokenContract, tokenId, account)` exists because
`register` and the counterfactual functions authorize on raw call parameters with no
stored `Binding` struct (counterfactual registrations never SSTORE a binding). It
could be collapsed into the single `Binding memory` overload by having
`_requireBindingControl` construct the struct, but this was intentionally NOT done in
this change: it is orthogonal to delegate support, both overloads pre-existed, and
this change already removed their duplicated logic (the struct overload now forwards
to the 4-arg one). If desired, the collapse should be a separate refactor commit with
its own test run, so the audited artifact here stays stable.

**Note 2 — DEL-01 and the emitter address.** The counterfactual `registrationHash`
is `keccak256(abi.encode(block.chainid, address(this), tokenContract, tokenId))` —
the emitter / `from` address is NOT part of it. A delegate emitting counterfactual
events therefore writes to the SAME record the owner's write would; it does not fork
or create a separate record. That is the intended behavior of delegation and is not
a concern. DEL-01 is specifically about `TokenStandard` exclusion on hybrid
ERC-721/ERC-1155 contracts, not the emitter address. Because a delegate acts on
behalf of the ERC-721 owner (not as a new independent principal), the marginal
security impact of this change on the pre-existing, design-accepted cross-standard
collision is minimal.

## Operational note for rollout

The Sepolia smoke test should confirm `DELEGATE_REGISTRY.code.length > 0` before the
Base and Ethereum upgrades.
