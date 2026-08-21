# Adapter8004 Counterfactual Attestation System — Type Registry Specification

**Version 1 · 2026-08-19**
**Revision:** attestation types are a closed `AttestationType` enum (§7). An earlier draft of this document specified open hash-named `bytes32` types; that scheme was not deployed. The change moved every `attestationId`, because `abi.encode` of an enum is its `uint8` rather than 32 raw bytes.
**Audience:** integrators building attesters, indexers, and consumers of counterfactual reputation.
**Scope:** the attestation surface of Adapter8004, its identifier scheme, its interpretation rules, and the v1 registry of attestation types. This document is normative for off-chain behavior — encodings, projection, and verification. The contract enforces only what §3 states.

---

## 1. Admission principle

A statement earns an attestation type only if there is a reason for the data to be **on-chain in the first place** — not merely because it is useful.

- `CONFIRM_ACCOUNT` is on-chain because the chain is where reciprocal verification happens: an account's consent must be independently checkable against the agent's forward claim by any verifier. The verification is live — it reflects the agent's current forward metadata and can change as that metadata changes.
- The reputation types are on-chain to create an **immutable, non-deletable event history**: no operator, platform, or subject can edit or erase what was said. An attestation's *active effect* may be revoked (§5); the record that it was made, and revoked, cannot.

Anything that fails this test — data that is merely convenient, mutable by nature, or verifiable nowhere — does not get a type, however useful. This test, not usefulness, is what any proposal for a new type must pass.

## 2. The surface

Three external functions, all emit-only. The adapter stores nothing and reads nothing about the target. The caller is always the attester or revoker; there is no path where one party acts for another, so consent can never be manufactured from outside the account, and a controller participates by causing the account itself to make the call.

```
attest(AttestationType attestationType, bytes32 cfid, bytes32 variant, bytes data)
confirmAdditionalAccount(bytes32 cfid)
revoke(bytes32 attestationId)
```

- **Targets.** `cfid` is an opaque `bytes32`; by convention it is an Adapter8004 counterfactual registration hash, derived as `keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, extraData))` with the standard as the enum's `uint8` and the discriminator reserved at zero. The standard in the identity records that the claimer passed that standard's authority probe at claim time, not that the contract conforms to the ERC. The contract cannot check any of this at attest time — counterfactual registration writes no storage, so no set of "real" hashes exists to check against — and does not try. A `cfid` that matches no claim or binding is **unresolved**: it acquires meaning if and when a counterfactual claim or on-chain binding gives it one. Attesting to a target before its first counterfactual claim is emitted is explicitly allowed; that is what counterfactual means.
- **The caller-is-attester rule** has a stated cost: an account that cannot make arbitrary outbound calls, such as a minimal vault or payment splitter with no executor, cannot confirm anything. That is a chosen limitation, not a gap. Ordinary wallets, multisigs, smart wallets with executors, timelocks, and EIP-7702-delegated accounts can all consent.
- **`confirmAdditionalAccount(cfid)`** is the plain-English entry point ordinary integrators call, equivalent to `attest(CONFIRM_ACCOUNT, cfid, 0, "")`.
- **`variant`** is caller-supplied and caller-interpreted: a counter, a random value, or anything else the attester finds useful. The protocol uses it for exactly one thing — distinguishing otherwise byte-identical attestations within a single block. Zero means no distinction is needed. It pairs with `block.number` in the identifier (§4): cross-block distinction is automatic; within-block distinction is opt-in via `variant`.

## 3. What the contract enforces, and what it deliberately does not

Enforced on-chain:

- `attestationType != UNSPECIFIED` and `cfid != 0` on `attest` and `confirmAdditionalAccount`, reverting `AttestationTypeZero` and `AttestationTargetZero`. This is a fail-closed sentinel rule against default-initialized calldata, not target validation — a nonzero garbage `cfid` passes.
- Type **range** validity, but not by any code in the contract: `attestationType` is a Solidity enum, so the ABI decoder reverts on a value above the last member before the function body runs. An out-of-range type can never reach the log, and no guard was written to achieve that.
- `revoke` checks nothing, deliberately, including a zero identifier. Revoking a statement that was never made is a recorded no-op under §5 rule 3, and a sentinel check would guard against nothing: an unset identifier field revokes nothing, harming nothing, where an unset type or target field would mint a statement in the wrong namespace.

Deliberately unenforced:

- **Target validity** — unverifiable (§2) and undesirable to verify, since pre-claim attestation is legitimate.
- **Payload well-formedness** — the adapter never decodes `bytes`. Every encoding rule in §7 is enforced at read time by consumers; malformed payloads are invalid at read, not reverted at write.
- **Submitter independence (anti-self-review)** — a per-type rule (§7), never contract-wide, and enforced by no contract. The adapter cannot resolve ownership for an unregistered counterfactual subject, because there is nothing on-chain to resolve. The rule therefore operates at aggregation: a reputation item passes the independence check only when the consumer can resolve the subject/controller relation and verify the attester is independent of it. Where that relation is not yet resolvable, the item **cannot pass the check** and stays outside trusted aggregation until resolution exists. Sybil resistance beyond this is the consumer's aggregation problem, as ERC-8004's own Security Considerations concede for its registry.
- **Revocation authorship** — verified in projection, not on-chain (§5, rule 4), because an emit-only contract cannot invert an `attestationId` to discover whose statement it identifies.

## 4. The attestation identifier

Every attestation has a deterministic id, **emitted by the contract** so integrators never need to recompute it (though they can):

```
attestationId = keccak256(abi.encode(
    _interoperableAddress(address(this)), // ERC-7930: chain + adapter, exactly as registrationHash binds
    attester,                             // the caller
    cfid,
    attestationType,                      // the enum's uint8, right-aligned in a word
    block.number,
    variant,
    data
))
```

There is no domain constant, deliberately. Domain separation is a device for stopping a signature valid in one context replaying in another, and nothing here is signed; both this identifier and the CFID are derived values, already bound to this contract and chain by the interoperable address in their preimages. The two schemes cannot collide: for any one adapter, the CFID encoding is a fixed 224 bytes and this encoding is at least 320, so the preimages can never even be the same length.

Rationale, recorded so the reasoning survives the decision:

- **`block.number` bounds a revocation's blast radius to one block.** Without it, an attester emitting byte-identical statements over time — a monitor issuing `isLive`-style pings — would collapse its entire history into a single id, and one revocation would erase all of it.
- **`variant`** is the within-block counterpart (§2): `block.number` distinguishes across blocks automatically; `variant` distinguishes within a block on demand. The name is deliberate: `salt` was rejected as jargon, and `extraData` already names the registrationHash discriminator throughout this contract.
- The **ERC-7930 interoperable address** binds the id to this adapter on this chain, mirroring `registrationHash`'s own domain binding. Consequence for cross-chain users: an attestation emitted on chain B — about a `cfid` derived anywhere — has a chain-B id, and its revocation must be sent to the same adapter on chain B.
- The **caller** in the preimage means the same statement from two different accounts is two different statements with two different ids.

## 5. Interpretation rules

Indexers apply events in log order.

1. **Collapse.** Byte-identical content — same attester, cfid, type, variant, data, and block — is one statement with one id, however many times it is emitted.
2. **Revocation withdraws the statement,** not one copy of it. `AttestationRevoked` for an id kills that id.
3. **Re-attestation reactivates.** Attest → revoke → attest leaves the statement active: a later block yields a fresh id, and within one block the identical id simply reactivates in log order. Revoking an id never attested, the zero identifier included, is recorded and does nothing.
4. **Revocation authorship is verified in projection.** A revocation affects state **only if** its caller equals the attester of the attestation bearing that id. All other revocations are inert noise; the contract stores nothing that would let it check this itself.
5. **State resurrection.** Revocation removes one statement and state projection selects the latest live one, so: rate 50, rate 80, revoke the 80 — the 50 is the current rating again. To hold no position, revoke every live statement of that type. For schemas that define a neutral value, attesting the neutral value is the alternative idiom — `STAR` defines one (`0`); `RATING` does not, because a rating of `0` is a rating, not the absence of one.

## 6. Projection classes

Every registered type declares exactly one class; the class is part of the published schema, not a consumer choice.

- **state** — the type expresses a current position. Projection: per `(attester, cfid, type)`, the latest un-revoked attestation is the value; none live means no position.
- **stream** — the type expresses a history. Projection: all un-revoked attestations accumulate; each is individually meaningful and individually revocable by id.

Revocation is orthogonal to both classes; rule 5 in §5 shows the interaction.

## 7. Type registry — v1

Types are members of a closed Solidity enum, `AttestationType`. The set is fixed by the deployed implementation: **admitting a sixth type is a contract upgrade**, not something a third party can do for itself. This is a deliberate choice of a closed namespace over an open one. An earlier draft used open hash-named `bytes32` values that anyone could mint under their own namespace; the enum was chosen because a type is what an enum is for, because `TokenStandard` in the same contract is already an enum, and because the contract is upgradeable, so the cost of admitting a type is an upgrade the owner can already perform.

Two consequences follow, one in each direction. The decoder enforces the range for free, so a garbage type is refused before any contract code runs and there is no guard to get wrong. And no third party can define a type without an upgrade, so the admission principle in §1 is now enforced by the upgrade process rather than by convention.

The numbering is **identity-critical**, exactly as `TokenStandard`'s is: the `uint8` sits in the `attestationId` preimage (§4), so renumbering a member re-keys every attestation ever emitted under it and every revocation that names one. Nothing on chain records the old value. **Append only, never reorder, never remove.**

| Member | `uint8` |
| --- | --- |
| `UNSPECIFIED` | `0` |
| `CONFIRM_ACCOUNT` | `1` |
| `STAR` | `2` |
| `RATING` | `3` |
| `REVIEW` | `4` |
| `INTERACTION` | `5` |

`UNSPECIFIED` occupies zero and is never a real type. Solidity enums start at zero, so without it the first real type would be the value a default-initialized variable carries, which is exactly what `AttestationTypeZero` exists to reject.

| Type | Payload encoding | Class | Submitter rule |
| --- | --- | --- | --- |
| `CONFIRM_ACCOUNT` | empty | state | attester is expected to be controller-adjacent; independence rules inapplicable by design |
| `STAR` | one byte: `0` or `1` | state | independence check per §3 |
| `RATING` | one byte: `0`–`100` | state | independence check per §3 |
| `REVIEW` | UTF-8 bytes, non-empty | stream | independence check per §3 |
| `INTERACTION` | `abi.encodePacked(uint8 score, bytes32 reference, bytes text)` | stream | independence check per §3 |

### `CONFIRM_ACCOUNT`

The attester states: *I am an additional account of the agent this cfid identifies.* It is the reciprocal half of the ERC-8048 forward metadata key `account[<chain-id>][<index>]`.

**Verification.** A confirmation counts only while the agent's forward `account` metadata lists the attester. The check is live: it reflects current metadata and its result changes when the metadata changes. Verification is **indexer-mediated**: ERC-8048 `account` entries are on-chain metadata, and although a stateless on-chain reader cannot enumerate metadata keys, the required `MetadataSet` event carries the full key string on every write. An indexer's historical log scan therefore yields the finite set of candidate `account[...]` keys as of its sync height, and current values are then read directly. An earlier draft of this system carried the forward index inside the confirmation payload on the assumption that verification had to construct the exact key without enumeration; the event-log route makes that unnecessary in an indexer-mediated system, and the payload is empty.

Submitter-independence rules do not apply: the attester is *expected* to sit in the agent's sphere of control — that is what the type asserts.

### `STAR`

An endorsement toggle. `1` stars the subject; `0` — the schema's neutral value — unstars it. Attesting `0` is the recommended idiom for toggles, reading as a position rather than a retraction. Attesting `0` and revoking the latest live `1` both project as unstarred immediately, but their histories differ: revocation can reveal an older live `1` under §5's resurrection rule. Aggregation: the **count** of attesters whose live state value is `1`. Any value other than `0` or `1` is invalid at read time.

### `RATING`

A quality rating, `0`–`100`, deliberately on ERC-8004's `starred` scale so mapping to that tag requires no scale conversion (five-star UIs map display-side). Aggregation: the **average** of each attester's live state value. `STAR` and `RATING` are separate types because they aggregate differently — stars are counted, ratings are averaged — and overloading either corrupts the other's arithmetic. Values above `100` are invalid at read time. `RATING` has no neutral value; to be unrated, revoke (§5, rule 5).

### `REVIEW`

Free-text reputation, on-chain as an immutable event record per §1 — a deliberate divergence from ERC-8004, which points at off-chain files (§8). The payload is the UTF-8 text; empty is invalid. Calldata cost is the author's by design.

### `INTERACTION`

A record of one dealing with the agent. Payload layout, total length ≥ 33 bytes:

- byte 0 — `score`, `uint8`, `0`–`100`; values above `100` invalid at read time
- bytes 1–32 — `reference`, identifying the dealing, typically a transaction hash; `bytes32(0)` when absent. It is NOT the cfid, which is already the target.
- bytes 33+ — `text`, optional UTF-8, may be empty

`abi.encodePacked` is safe here because only the final field is dynamic, and it saves roughly 95 bytes of ABI overhead per attestation versus `abi.encode`.

## 8. ERC-8004 mapping

This system is the counterfactual counterpart of ERC-8004's Reputation Registry: ERC-8004 targets a registered `agentId`; this system targets a `cfid`. For any adapter-registered agent the two histories join automatically — `bindingOf(agentId)` yields the standard, bound address, and token id from which its counterfactual-era `registrationHash` derives, so the merge is a projection join requiring no transaction and no link assertion. A registration joins only the counterfactual history claimed under its own standard, so one coordinate can carry separate histories per standard. The `TokenStandard` numbering is identity-critical for the same reason: new standards append, and renumbering is forbidden forever. `registrationHashOf(agentId)` performs that derivation on chain, so a consumer holding a registered `agentId` gets the counterfactual identifier in one call. An earlier draft of this document described a reserved `cf-registration` metadata key held for a future promotion flow; that reservation was removed at `0.0.17`, because the value is derivable and a stored copy would be both redundant and spoofable.

**This system → ERC-8004:**

| This system | ERC-8004 | Notes |
| --- | --- | --- |
| `RATING` | `giveFeedback` with `tag1 = "starred"` | same 0–100 scale, no conversion |
| `REVIEW` | the off-chain file at `feedbackURI` (+ `feedbackHash`) | divergence: this system puts text on-chain; ERC-8004 points off-chain |
| `INTERACTION` | closest analogue: feedback carrying `endpoint`/`proofOfPayment` context | no exact counterpart |
| `STAR` | none | `endorsed` (binary) should be proposed upstream for ERC-8004's suggested tag table |
| `CONFIRM_ACCOUNT` | none in the Reputation Registry | it is the reverse of ERC-8048's `account` metadata key, not a reputation signal |
| `revoke(attestationId)` | `revokeFeedback(agentId, feedbackIndex)` | id vs index; same intent |
| `attestationId` | `feedbackIndex` | both identify one statement by one author about one subject |

**ERC-8004 → this system.** The monitoring tags `reachable`, `uptime`, `successRate`, `responseTime`, and `blocktimeFreshness` have no v1 types. `INTERACTION` does not structurally encode endpoint, latency, reachability, or block freshness, so it cannot generally supersede those signals or soundly derive all of them; derivation from the `INTERACTION` stream is appropriate only where its evidence and schema actually suffice for the metric in question. Future monitoring types remain possible under §1, as enum members added by upgrade. `appendResponse` maps to the deferred reply mechanism (§9). `getSummary` and `readAllFeedback` map to indexer queries; there are no on-chain reads here.

**Structural divergences, stated plainly:**

- **ERC-8004 stores; this system emits.** ERC-8004 keeps values, tags, and revocation flags in contract storage for on-chain composability; this system is emit-only, so all reads are indexer reads and no contract can consume counterfactual reputation on-chain. Accepted deliberately.
- **Projection models differ.** ERC-8004 intentionally models feedback as an item stream aggregated across all un-revoked items; `RATING` and `STAR` here are state types resolving latest-per-attester. When merging histories across the boundary, the consumer must choose an aggregation strategy explicitly — collapse ERC-8004 items latest-per-client to match this system's state model, or keep both models and accept the discontinuity. This specification does not, and cannot, normatively rewrite ERC-8004's model.
- **ERC-8004's self-review prohibition** is a contract rule there and an aggregation-time independence check here (§3).

## 9. Deferred

- **Validation** (ERC-8004's Validation Registry pattern): a two-party **authorized state machine** — named validator, gated request, progressive storage-backed status — not an attestation. An emit-only system has no enforcement to offer it; agents needing validators should register.
- **Replies / `appendResponse`:** now that `attestationId` exists, a reply is an attestation type whose payload references an id — no contract change is needed, so it waits until feedback threading demonstrates demand.
- **Monitoring types:** not in v1 (§8). Measured signals may be derived from `INTERACTION` where its schema suffices; dedicated types remain possible under the admission principle, appended to the enum by upgrade.

## 10. Events

- `Attested(address indexed attester, AttestationType indexed attestationType, bytes32 indexed cfid, bytes32 attestationId, bytes32 variant, bytes data)`, whose ABI signature is `Attested(address,uint8,bytes32,bytes32,bytes32,bytes)`
- `AttestationRevoked(bytes32 indexed attestationId, address indexed revoker)`

Topic allocation follows three canonical query axes on attestation: reverse by `attester`, forward by `cfid`, and filter by `attestationType`. The `attestationId` is recomputable from the event fields plus its log context, including block number, and is therefore non-indexed on `Attested`. On `AttestationRevoked` the id is the join key and is indexed. `attester` and `revoker` are the actual `msg.sender` in every event; there is no separate submitter field because there is nothing left to distinguish.
