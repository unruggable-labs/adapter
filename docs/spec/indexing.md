# Adapter8004 Counterfactual Indexing Specification

**Status:** Accepted 2026-08-12 — normative for the `0.0.16` baseline (decisions D1-D6 signed
off, R-7 ratified; no open questions)
**Applies to:** the unreleased `0.0.16` source (ERC-7930 v1 encoding frozen in the preimage,
canonical subject-identifier grammar). See [`docs/decisions/phase1-freeze.md`](../decisions/phase1-freeze.md)
for the decisions this spec encodes (D1–D6).
**Conformance:** the key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as in
RFC 2119. An indexer conforms iff it produces the required end state for every fixture in
[`docs/spec/fixtures/`](./fixtures/).

Counterfactual identity is event-sourced: the adapter writes no counterfactual state on-chain,
so **the indexer is the database, not a cache**. Two conforming indexers MUST agree on the
resolved state of every identity given the same logs. Everything in this document exists to make
that true.

---

## 1. Identity model

- **I-1.** The identity of a counterfactual agent IS its `registrationHash`. Indexers MUST key
  identities on the hash, never on coordinates: one contract may carry many identities (token
  subjects, its own contract subject, and future identifier kinds).
- **I-2.** One preimage for every subject kind (decision D6), over standard ABI encoding of
  `(bytes, address, bytes)`:

  `registrationHash = keccak256(abi.encode(adapterInteroperableAddress, tokenContract, identifier))`

  where `identifier` is the canonical subject identifier:

  | Subject | Identifier | Length |
  |---|---|---|
  | The contract itself (`CONTRACT`, `CONTRACT_OWNABLE`) | empty | 0 |
  | Plain token (all five token standards) | `0x00 || tokenId` (full-width 32-byte big-endian) | 33 |
  | Future kinds | `<kind byte >= 0x01> || kind-defined layout` | per kind |

  The adapter bytes are the standard **ERC-7930 v1** Interoperable Address
  (`Version(0x0001) || ChainType(2) || RefLen(1) || Ref || AddrLen(1) || Address(20)`), frozen at
  version `0x0001` in the preimage permanently (INV-1, decision D1 revised); `tokenContract` is a
  naked EVM address. Vectors: [`adapter-counterfactual-hashes.md`](../fixtures/adapter-counterfactual-hashes.md).
  Every counterfactual event carries its `identifier` as the first body field, so any single event
  is self-verifying: recompute the hash from `(adapter, tokenContract topic, identifier)` and it
  MUST equal the event's hash topic. Indexers SHOULD validate this and MUST drop events that fail.
- **INV-2 (encoding freeze).** Identifier encodings are canonical and permanent: the empty
  identifier means the contract subject forever; every non-empty identifier begins with an
  append-only kind byte; kind `0x00` is the full-width token id (never minimal-length); kind
  layouts never change once published. A future implementation introduces new kinds only —
  it MUST NOT re-encode a subject that already had an identifier under an existing kind (that
  would re-key a live identity). An indexer observing an unknown kind byte MUST treat it as a
  distinct, opaque identity, never as a re-encoding of a known subject.
- **I-3 (chain scope).** Identities are chain-scoped by construction (the adapter bytes embed
  the chain). Indexers MUST NOT merge identities across chains or across adapter deployments.

## 2. Event catalog

State-transition events (counterfactual projection):

All six counterfactual events share the indexed topics
`(registrationHash, tokenContract, emitter)` and carry the canonical `identifier` (`bytes`) as
their first body field:

| Event | Effect (see §4) |
|---|---|
| `CounterfactualAgentRegistered(hash, token, emitter, identifier, standard, agentURI, metadata[])` | (re)registration: resets URI, metadata, standard |
| `CounterfactualAgentURISet(hash, token, emitter, identifier, newURI)` | replaces `agentURI` |
| `CounterfactualMetadataSet(hash, token, emitter, identifier, key, value)` | upserts one metadata key |
| `CounterfactualMetadataBatchSet(hash, token, emitter, identifier, metadata[])` | upserts each entry in order |
| `CounterfactualAgentWalletSet(hash, token, emitter, identifier, newWallet)` | sets `agentWallet` |
| `CounterfactualAgentWalletUnset(hash, token, emitter, identifier)` | clears `agentWallet` only (field-level; there is no whole-claim tombstone) |

Primary-agent events (two independent projections, §6):

| Event | Projection | Role |
|---|---|---|
| `PrimaryAgentSet(account, uint256 agentId, setBy)` | full ERC-8004 | state transition |
| `PrimaryAgentCleared(account, clearedBy)` | full ERC-8004 | state transition |
| `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)` | full ERC-8004 | provenance only |
| `PrimaryAgentClearedWithSig(account, relayer, nonce)` | full ERC-8004 | provenance only |
| `PrimaryCounterfactualAgentSet(account, hash, setBy, token, identifier)` | counterfactual | state transition |
| `PrimaryCounterfactualAgentCleared(account, clearedBy)` | counterfactual | state transition |

`AgentBound` and the other full-registration events are **not** part of the counterfactual
projection (§7).

## 3. Ordering

- **O-1.** Events are totally ordered by `(blockNumber, logIndex)` within a chain. `logIndex`
  is block-scoped, so this order is total; there are no ties. Indexers MUST apply events in
  this order and MUST NOT use transaction position, timestamps, or arrival order.
- **O-2 (reorgs).** On a reorg, indexers MUST discard state derived from orphaned blocks and
  replay from the fork point. Indexers SHOULD expose the finality depth they consider settled;
  consumers of unfinalized rows do so at their own risk. Reorg handling MUST be equivalent to
  a fresh replay of the canonical log (no residue from orphaned events).

## 4. Counterfactual resolution

Identity state is a fold over the identity's events in O-1 order:

- **R-1 (registration resets).** `CounterfactualAgentRegistered` sets
  `registered = true`, `standard`, `agentURI`, and **replaces** the metadata map with exactly
  the entries carried by the event. It is a full re-statement of the claim, not a merge.
- **R-2 (field semantics).** URI-set replaces the URI; metadata-set and each batch entry
  upsert single keys; wallet-set/unset act on the wallet field alone. Field events apply even
  when they precede any registration: `registered` stays `false` until a registration event is
  seen, indexers MUST retain the fields either way, and default read APIs MUST surface such
  identities with the `registered: false` flag rather than hiding them — hiding data the chain
  contains is how two conforming indexers come to disagree. Consumers filter on the flag.
- **R-3 (latest wins).** Within one authority class (R-4), the latest event per field per
  identity is authoritative.

### Authority classes (decision D3)

- **R-4 (classification).** An event is **contract-authored** iff `emitter == tokenContract`;
  otherwise it is **owner-authored**. (On-chain authorization already vetted the emitter; the
  indexer's job is only to rank the two classes.)
- **R-5 (subordination — token subjects).** For token-subject identities: once any
  owner-authored event exists for the identity, every contract-authored event at a later O-1
  position MUST be ignored. Contract authority is valid only before the first owner-authored
  event (the pre-mint window); anything later is post-burn or spoofing and never supersedes an
  owner's claim.
- **R-6 (contract subjects are a separate namespace).** Contract-subject identities (empty
  identifier, I-2/D6) are distinct from every token identity of the same contract; R-5 never
  applies to them. The former OPEN-1 (aliasing at `(X, 0)`) is resolved by construction.
- **R-7 (contract-senior subordination, decision D6).** For contract-subject identities:
  contract-authored events (`emitter == tokenContract`) outrank owner-authored ones (any other
  emitter — the `CONTRACT_OWNABLE` `owner()` route). Once any contract-authored event exists
  for the identity, every owner-authored event at a later O-1 position MUST be ignored.
  Owner authority is valid only before the contract's first utterance: an `owner()` may
  bootstrap the identity of a contract with no outbound call path, but a contract that speaks
  for itself can never be superseded by a stale or hostile `owner()` key. (Mirror of R-5 with
  inverted seniority; the discriminator is the indexed `emitter` topic.)

### Advisories (non-normative)

- Verifiers SHOULD flag an identity whose bound token is *currently* ownerless
  (`ownerOf` reverting or zero) at read time.
- Holders SHOULD clear primary pointers before burning a bound token.
- A current owner can author hostile events until the moment of transfer (seller poisoning);
  buyers SHOULD re-state the claim after acquiring a bound token.

## 5. Trust semantics

Counterfactual state is **claims, not proof**. `CounterfactualAgentWalletSet` carries no
consent from the named wallet. A verified account↔agent link additionally requires the
mutual-pointing check: the identity names the wallet AND `primaryCounterfactualAgentOf(wallet)`
(or `primaryAgentOf` on the full side) names the identity. Indexers SHOULD expose both
directions; they MUST NOT present a wallet claim alone as verified.

## 6. Primary-agent projections

- **P-1.** Two independent projections: full (`address → uint256 agentId`) and counterfactual
  (`address → registrationHash`). Setting one never affects the other.
- **P-2.** State transitions come ONLY from the legacy events (`PrimaryAgentSet`/`Cleared`,
  `PrimaryCounterfactualAgentSet`/`Cleared`). The `*WithSig` events are supplemental
  provenance (authorization method, relayer, consumed nonce) and MUST NOT be applied as a
  second transition.
- **P-3.** "Unset" is the absence of a row (contract-side: the all-ones sentinel). Agent id
  `0` is a real, settable id and MUST NOT be treated as null.

## 7. Independence of the two identity systems (decision D2)

Counterfactual identity is the primary system; full ERC-8004 registration is a parallel,
independent one. `AgentBound` (or any full-registration event) for the same coordinates MUST
NOT end, outrank, link to, or otherwise affect the counterfactual identity, and vice versa.
There is no promotion flow and no `cf-registration` back-link; nothing writes that key.
Indexers MAY surface "a full registration also exists for these coordinates" as a discovery
hint, never as supersession.

## 8. Cutover appendix (per deployment — to be filled at Sepolia deploy)

| Chain | Adapter proxy | Cutover block | `chainIdentifier()` | Sample hash |
|---|---|---|---|---|
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | TBD | `0x0001000003aa36a700` | TBD |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | TBD | `0x0001000002210500` | TBD |
| Ethereum | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | TBD | `0x00010000010100` | TBD |

Events before a chain's cutover block (old ABIs, old hash schemes) are versioned legacy
history; indexers MUST NOT re-key them into the current namespace.

## 9. Conformance fixtures

Machine-readable fixtures live in [`fixtures/`](./fixtures/); the schema is documented in
[`fixtures/README.md`](./fixtures/README.md). Each fixture is an event sequence plus the
required end state. A conforming reducer reproduces every `expected` block exactly. The
reference reducer ships with the SDK (Phase 1, Workstream B) and MUST pass all fixtures.

## Open questions

- **OPEN-1:** resolved by decision D5 (contract subjects hash without a `tokenId`; see I-2 and
  R-6).
- **OPEN-2:** resolved 2026-08-12 — unregistered identities are surfaced by default with
  `registered: false` (see R-2). No open questions remain.
