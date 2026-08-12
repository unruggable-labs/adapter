# Phase 1 freeze decisions

**Status:** decided and signed off 2026-08-12 (all of D1–D6, including ratification of R-7 and
resolution of D4 as `0.0.16`)
**Date:** 2026-08-11 (D1–D5); 2026-08-12 (D1 revised, D4 resolved, D6, R-7 ratified)
**Deciders:** Thomas Clowes, Prem Makeig
**Scope:** the decisions that a Sepolia deployment of the `0.0.16` source makes permanent. Each
was free to change before deployment and is a hard cutover after it.

---

## D1. Counterfactual hash preimage: ERC-7930 v1 encoding, frozen (REVISED 2026-08-12)

**Decision (revised).** ERC-7930 will NOT be modified: the ecosystem (OpenZeppelin's
Interoperable Address library, the interop SDK, ERC-7828) uses the standard as published, and
compatibility with those implementations outweighs the dead-bytes concern. The adapter keeps the
standard **v1 encoding, version bytes included**, in both the public views and the hash preimage:

```
Version(0x0001) || ChainType(2) || ChainReferenceLength(1) || ChainReference || AddressLength(1) || Address
```

The chain-only identifier (used in ERC-8048/8049 `address[<chain-id>]` keys) is likewise the
standard form: Ethereum mainnet is `0x00010000010100` — matching the published ERC-8049
ERC-20Agent example and every existing 7930 implementation. Hashes are computable with stock
ERC-7930 encoders.

**INV-1 (freeze by declaration).** The preimage uses the ERC-7930 **version-`0x0001`** encoding
permanently. If a future ERC-7930 version ever changes the format, it may affect the public
`interoperableAddress()` / `chainIdentifier()` views only via a deliberate, documented split;
it never affects `_registrationHash`. v1 bytes mean v1 things forever.

**History.** The original D1 (2026-08-11) removed the version bytes on the assumption ERC-7930
itself would drop the version field. That spec change was abandoned on 2026-08-12 in favor of
ecosystem compatibility; the version-free encoding was implemented and then reverted in the same
unreleased working tree, and no version-free hash was ever published or deployed.

## D2. No promotion. Counterfactual is the primary identity system

**Decision.** No promotion flow will be built. Counterfactual registration is THE intended
identity path; full ERC-8004 registration through the adapter remains available but is a
parallel, independent system.

**Consequences (normative for the indexing spec):**
- No supersession in either direction: an `AgentBound` for the same `(tokenContract,
  tokenId)` does not end, outrank, or link to the counterfactual identity, and counterfactual
  events never affect a full registration.
- `cf-registration` remains reserved-but-unwritten permanently. Its reservation is purely
  defensive (no caller may fabricate a provenance claim under it); nothing will ever write it.
- The spec, SDK, and UI present counterfactual identity as the default path and full
  registration as an explicit alternative, not an upgrade target.

## D3. Burn-epoch rule: emitter subordination (spec-only)

**Decision.** The indexing spec adopts the emitter-subordination rule for counterfactual
resolution:

> Owner-authored events (`emitter != tokenContract`) always outrank collection-authored
> events (`emitter == tokenContract`) for the same `registrationHash`. Within each class,
> the latest event by `(blockNumber, logIndex)` wins.

**Rationale.** The collection-authority window reopens when a bound token is burned
(`ownerOf` reverts or returns zero). Under plain latest-event-wins, a post-burn
collection-authored event would retroactively supersede an identity a real owner had built —
the one genuinely new capability the ownerless window created. Because every counterfactual
event carries `emitter`, collection-authored events are self-identifying from adapter logs
alone; this rule kills the post-burn takeover with no contract change and no external
token-contract watching.

**Accepted residuals (documented, not fixed):**
- A burn-and-reissue flow that legitimately wants a collection-authored reset shows the prior
  owner's data until the new owner emits once.
- A current owner can still author a hostile event in their last block of ownership
  (seller poisoning); owner-authored events are not subordinated. Read-time advisory applies.

**Advisory (folded into the spec):** verifiers SHOULD flag an identity whose bound token is
currently ownerless; holders SHOULD clear primary pointers before burning.

## D4. Version bump (RESOLVED 2026-08-12)

**Decision.** The release ships as **`0.0.16`**, collapsing the never-deployed `0.0.15` into it:
the interim `extraData` scheme existed only in unreleased source, so its changelog content is
absorbed into the `0.0.16` entry (net changes only) and its hash scheme is retained solely in the
hash-fixture doc's superseded tables for reimplementer identification.

## D5. Contract subjects hash without a tokenId (resolves spec OPEN-1) — superseded by D6

**Decision.** Counterfactual identities have two subject types with two preimages:

```
token subjects:    keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId, extraData))
contract subjects: keccak256(abi.encode(adapterInteroperableAddress, tokenContract, extraData))
```

`CONTRACT` and `CONTRACT_OWNABLE` claims are contract subjects: the subject is the contract
itself, there is no token, and no `tokenId` appears in the hash. The `tokenId == 0` calling
convention is unchanged and the value is carried in events as a placeholder attribute only.

**Rationale.** The previously accepted aliasing — contract X and its own token id `0` sharing one
identity at `(X, 0)` — created an unresolvable authority contest wherever a real token #0 exists
(the owner of #0 and the contract itself are both permanent, legitimate writers). Ranking rules
either produced ping-pong or permanently disenfranchised one party, and banning token id `0` would
exclude real assets from a namespace the adapter does not own. Modeling the subject directly
dissolves the contest: the preimage contains exactly the fields that define the subject. An
`extraData` discriminator was considered and rejected as overloading the reserved field with a
second meaning before its intended use.

**Collision safety.** The two preimages cannot collide: canonical ABI encoding places the `bytes`
tail at offset `0x80` for the 4-field token tuple and `0x60` for the 3-field contract tuple, so
the encoded domains are disjoint in their first word (pinned by test).

**Surface.** New `registrationHash(address)` view overload and contract-subject overloads of
`setPrimaryCounterfactualAgent[For]`. Event ABIs unchanged.

## D6. Canonical subject identifiers (2026-08-12; supersedes D5's mechanism and removes `extraData`)

**Decision.** One counterfactual preimage for every subject kind:

```
registrationHash = keccak256(abi.encode(adapterInteroperableAddress, tokenContract, identifier))
```

where `identifier` is `bytes` with a canonical, frozen grammar:

| Subject | Identifier | Length |
|---|---|---|
| The contract itself (`CONTRACT`, `CONTRACT_OWNABLE`) | empty | 0 |
| Plain token (all five token standards) | `0x00 || tokenId` (full-width 32-byte big-endian, never minimal) | 33 |
| Future kinds | `<kind byte >= 0x01> || kind-defined layout` | per kind |

**Grammar rules (normative, frozen).** The empty identifier is reserved for the contract subject
forever; every non-empty identifier begins with an append-only kind byte; kind layouts are frozen
once published; token ids are always full-width. `abi.encode` of `bytes` is length-prefixed, so
the preimage is injective and its shape never changes again — future subject kinds extend the
grammar, never the formula.

**`extraData` is removed** (contract constant, preimage field, and event field). Its stated purpose
— discriminating subjects that share a `(tokenContract, tokenId)` — is served natively and more
expressively by identifier kinds (e.g. a class-token kind `0x01 || class || id`), and its
prose activation invariant (old INV-2) is replaced by the simpler encoding-freeze rules above.

**Events.** All six counterfactual events and `PrimaryCounterfactualAgentSet` are reworked:
indexed topics `(registrationHash, tokenContract, emitter)` — the freed `tokenId` slot now indexes
the authorizing caller — and the canonical `identifier` rides as the first body field, making every
event self-verifying against its own hash topic. No `tokenId` and no `extraData` field exists in
any counterfactual event. Hard topic0 cutover; nothing is deployed on the prior ABI.

**Entry points (no placeholder anywhere).** Contract subjects use dedicated tokenId-free functions
— `registerContract` (+ metadata overload), `registerContractAndSetPrimary`,
`bindExistingContract`, `counterfactualRegisterContract` (+ overload), and the five
`counterfactualSetContract*` / `counterfactualUnsetContractAgentWallet` writers — while the token
surface rejects contract standards (`NotTokenStandard`) and the contract surface rejects token
standards (`NotContractStandard`). The one residual zero is `Binding.tokenId` for contract
bindings: an unavoidable storage struct default, documented, never caller-supplied and never part
of any identity.

**R-7 (contract-senior subordination; spec-only — RATIFIED 2026-08-12).** For contract-subject identities, indexers rank
contract-authored events (`emitter == tokenContract`) above owner-authored ones: once any
contract-authored event exists, later owner-authored events are ignored. Mirrors D3 with inverted
seniority — pre-first-utterance an `owner()` may bootstrap a silent contract's identity, but a
contract that speaks for itself can never be superseded by a stale or hostile `owner()` key. This
also corrects the "opt-in, never assumed" claim for `CONTRACT_OWNABLE` on the counterfactual
surface, where the authority model is chosen per call rather than stored.

**Rationale trail.** D5 separated the subjects by preimage arity (structural luck, fragile under
future kinds); a tagged-tuple variant would have fixed that but kept a vestigial in-hash tokenId;
the identifier grammar keeps the tag (as the kind byte), models absence honestly (empty bytes is
the ABI's one true null), deletes `extraData`, and yields self-verifying events.

---

## Sequencing note

D1's and D6's contract changes must land and be reflected in fixtures before any Workstream C
(Sepolia) activity. D2, D3, and D6's R-7 are spec-layer rules consumed by Workstream A and the
Workstream B reducer.
