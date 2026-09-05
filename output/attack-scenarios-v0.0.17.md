# Adapter8004 v0.0.17 — 20 simulated attack scenarios

**Status: IDEATION ONLY.** No exploit code, no tests, no contract changes were produced or are
proposed here. Execution is a separate, separately-approved task.

Authorized internal adversarial review of our own contract. Target
`/Users/nxt3d/projects/adapter-0.0.17`, branch `v0.0.17`, clean tree, 401 tests green.
Primary file `src/Adapter8004.sol` (`@custom:version 0.0.17`) plus `src/interfaces/`.

Produced by `adapter` (lead) and `seniordev` (independent second read). seniordev read the
contract and the prior audits without seeing any list from `adapter`; the two lists were merged
afterwards. Attribution per scenario is recorded below, and the disagreements are in §4 rather
than smoothed away.

---

## 1. The coverage baseline, and why it matters

The most important input to this exercise is what the prior audits actually cover.

All six audit files are dated 2026-04-30 / 2026-05-07 and record test counts of **91 → 102**.
The tree today has **401**. Those audits were scoped to the ERC-8217 migration: interface
completeness, the `agent-binding` reserved key, controller checks over ERC-721/1155/6909,
storage layout, and the (since-removed) `rewriteBindingMetadata` helper. Their "Findings"
sections contain one Low (an interface omission) and a handful of informational notes.

They therefore **predate essentially the entire v0.0.17 authority and identity surface**:

| Surface | Present in the audited version? |
|---|---|
| `ACCOUNT`, `CONTRACT_OWNABLE`, `CONTRACT_ADMIN` standards | No |
| delegate.xyz v2 integration (all four routes) | No |
| UBID / `hashBinding` / counterfactual identities | No |
| Attestation surface (`attest` / `confirmAdditionalAccount` / `revoke`) | No |
| Wallet→UBID reverse designation | No |
| Immutable `identityRegistry`, dead slot 0, `RegistryMismatch` | No |

So "not covered by prior audits" is true of most of what follows, and is a weak claim on its
own. The load-bearing coverage question for v0.0.17 is **the test suite**, which is large and
genuinely adversarial (`test/security/`: adversarial, security, counterfactual,
counterfactual-unminted, ownerless-register, fuzz, invariants). Each scenario below states what
the existing tests do prove and where the gap is. Several candidates were **cut** during this
pass precisely because a test already covered them — those are listed in §5.

---

## 2. The twenty scenarios

Prior is a calibrated judgement about **whether the mechanism works as described**, held
separately from severity. Distribution: **6 likely / 12 plausible / 2 long shot**.

---

### A. Authority resolution and `isController`

#### 1. Reverting-`ownerOf` collection: perpetual self-authority plus buyer lockout
*Attribution: converged (both lists, independently).* **Prior: likely.**

**Goal.** A hostile single-owner collection keeps permanent authority over every identity bound
to it — including tokens it has already sold — while simultaneously making the legitimate
buyer's control checks unusable.

**Preconditions.** Attacker deployed (or can upgrade) the bound ERC-721 / ERC-1155F / ERC-6909F
collection. No control of the adapter, the registry, or the victim's keys.

**Mechanism.** The adapter reads `ownerOf` through two paths with **opposite failure semantics**.
`_hasNoCurrentOwner` (`src/Adapter8004.sol:738-746`) treats a *reverting* `ownerOf` as
"no current owner" and returns `true`, which opens the collection-authority window in
`_requireTokenAuthority:723-729`. `_hasBindingControl` step 4 (`:806-815`) calls
`ISingleOwnerToken(boundAddress).ownerOf(tokenId)` **unwrapped**, so the same revert propagates
out of `_requireController` and `isController`. A collection that reverts `ownerOf` at will
therefore holds the ownerless window open forever — even for minted, owned tokens — while the
buyer's `isController` and every gated write revert.

**Falsification.** `RevertingOwnerOf721` mock; assert the collection can still drive every
counterfactual writer after a real mint, and that `adapter.isController(agentId, buyer)` reverts
rather than returning `false`.

**Why not already covered.** `testMaliciousERC721CanFlipControl` /
`testMaliciousERC721GrantsControlToForcedOwner` exploit the *owner-flip* branch — `ownerOf`
returns a different address. `testMalformedSuccessfulOwnerOfResponsesFailClosed` and
`testDirtyAndWrongLengthOwnerResponsesFailClosed` cover malformed *successful* returns.
`testBurnReopensOnlyCollectionOwnerlessWindow` covers a genuine burn. Nothing covers
**fabricated ownerlessness by revert while a real owner exists**, which is the branch that grants
authority rather than denying it.

---

#### 2. `isController` is not a total function
*Attribution: adapter (seniordev's #5 reaches the same asymmetry from the other side).*
**Prior: plausible.**

**Goal.** Break every integrator that treats `isController` as a boolean oracle, by making it
revert. A gate written as `if (!adapter.isController(id, user)) revert;` fails closed and bricks
the user; one written as a `try/catch` with a permissive default fails **open**.

**Preconditions.** Any binding whose authority probe can revert: a burned ERC-721, an ERC-1155
whose `balanceOf` reverts, or a delegate.xyz registry that reverts.

**Mechanism.** `isController:279-290` documents and implements exactly one total case — unknown
agent returns `false` (`:284-286`). Every other path can revert: `ownerOf` at `:808`,
`IERC1155.balanceOf` at `:821`, `IERC6909.balanceOf` at `:826`, and the three delegate.xyz
probes at `:867`, `:878`, `:891`, none of which wrap the external call. This contrasts with
`_currentContractOwner:840-857` and `_hasDefaultAdminRole:644-649`, which are deliberately
fail-closed. The contract is internally inconsistent about whether an authority probe may revert.

**Falsification.** Bind ERC-721, burn the token, assert `isController` reverts; repeat with a
`balanceOf`-reverting ERC-1155 and with `vm.etch`-ing a reverting contract at `DELEGATE_REGISTRY`.

**Why not already covered.** The never-reverts property is asserted only for unknown agents
(`test/Adapter8004.delegate.t.sol:253`, `test/security/Adapter8004.invariants.t.sol:115`,
`testIsControllerUnknownAgentReturnsFalse`). `testFuzzUnknownAgentRevertsAcrossAllGatedReads`
tests the unknown-agent revert taxonomy, not probe failure on a *known* agent.

---

#### 3. Transient control: flash-borrowed ERC-1155/6909 balance rewrites an identity
*Attribution: adapter only.* **Prior: likely.**

**Goal.** Rewrite an identity's `agentURI`, metadata, and agent wallet without ever holding
control for longer than one transaction — then hand the tokens back.

**Preconditions.** The bound ERC-1155 or ERC-6909 id has any liquidity: a lending pool, an AMM,
an ERC-3156-style flash route, or simply a willing counterparty for an atomic buy/sell.

**Mechanism.** ERC-1155 and ERC-6909 control is a bare positive-balance test —
`_hasBindingControl` steps 5 and 6, `:819-826`: `balanceOf(account, tokenId) > 0`. There is no
minimum holding period, no snapshot, no block-delay, and no notion of a *majority* holder. One
wei of balance is full control. `setAgentURI:190`, `setMetadata:201`, `setMetadataBatch:221` and
`unsetAgentWallet:253` all gate on exactly this. Acquire → write → return, atomically. The same
shape applies to ERC-721 via NFT lending, with the extra step of a borrow.

**Falsification.** Single transaction: acquire 1 unit of the bound id, call `setAgentURI`, return
the unit; assert the URI changed and the attacker's end-of-transaction balance is zero.

**Why not already covered.** Every control test mints and holds
(`test1155ControlIsAnyCurrentHolder`, `testFuzzControl1155FollowsBalances`,
`test1155TransferOutDropsControl`). `test1155TransferOutDropsControl` proves control *ends* on
transfer-out; no test acquires control transiently and writes inside the window. Grep for
`flash`/`borrow` across `test/` and `src/` returns nothing.

---

#### 4. `owner()` that echoes `tx.origin` makes `isController` tell every caller they are in control
*Attribution: adapter only.* **Prior: plausible.**

**Goal.** Produce a contract-bound identity for which `isController(agentId, X)` returns `true`
for *whoever is asking*, so an off-chain verifier — or a phishing page — can "prove" that the
visitor controls a marquee agent.

**Preconditions.** Attacker deploys the bound contract and binds it `CONTRACT_OWNABLE`.

**Mechanism.** `_currentContractOwner:840-857` `staticcall`s `owner()` and accepts any single
clean address word. `tx.origin` is readable inside a `staticcall`. For an `eth_call` with
`from: X` — the standard way a dApp or indexer asks "does this user control this agent?" —
`tx.origin` is `X`, so `owner()` can return `X` and `_hasBindingControl` step 2 (`:786-797`)
returns `true` for every distinct caller. On a real transaction the same trick makes the actual
sender the owner, so writes succeed for anybody too.

**Falsification.** `TxOriginOwnable` mock; assert `isController(agentId, alice)` and
`isController(agentId, bob)` are both `true` from the respective `from` addresses in one block.

**Why not already covered.** The adversarial mocks (`MaliciousERC721`, the ownable mocks) return
*fixed or explicitly-set* owners. `testDirtyAndWrongLengthOwnerResponsesFailClosed` and
`testMalformedSuccessfulOwnerOfResponsesFailClosed` cover malformed shapes. No mock returns a
**caller-dependent well-formed** answer, which is the case the fail-closed word check cannot see.

---

#### 5. Permissive or self-grantable `DEFAULT_ADMIN_ROLE` under `CONTRACT_ADMIN`
*Attribution: converged (adapter + seniordev #7).* **Prior: plausible.**

**Goal.** Seize, or share, control of an identity that *looks* admin-gated.

**Preconditions.** The bound contract's role-`0x00` predicate is satisfiable by the attacker:
an open DAO with public `grantRole`, a buggy role setup, or any contract whose fallback returns
a nonzero 32-byte word for an unrecognised selector.

**Mechanism.** `_hasDefaultAdminRole:644-649` accepts **any nonzero word** returned by
`hasRole(bytes32(0), account)` — deliberately, to avoid a `bool` decode reverting on non-conforming
data. That fail-*open*-on-nonzero shape means a catch-all fallback returning nonzero data grants
everyone admin. `_hasBindingControl` step 3 (`:800-802`) is a bare pass-through with no
delegation and no other check, and the adapter never verifies the bound contract is really
AccessControl.

**Falsification.** (a) `PublicGrantAdmin` where anyone self-grants role `0`; (b) a contract with a
fallback returning `bytes32(1)`; assert a stranger passes `isController` in both.

**Why not already covered.** `testContractWithoutHasRoleCannotBeBound` covers *absence* of
`hasRole`; `testAdminBindsAndManages` and `testNonAdminIsDenied` cover a single well-behaved
admin. `testDirtyBooleanReturnIsHandled` covers a dirty bool from an otherwise honest contract.
Permissive-by-construction and fallback-returns-nonzero are untested.

---

### B. `ACCOUNT` and delegate.xyz

#### 6. The `ACCOUNT` delegate route contradicts the README's own security rationale — and an unrelated blanket grant is an instant takeover
*Attribution: seniordev (found), adapter (verified and extended).* **Prior: likely.**

**Goal.** Control an `ACCOUNT`-bound identity from the moment the victim binds, with no
interaction from the victim and nothing the victim can undo.

**Preconditions.** The victim's EOA already holds a delegate.xyz v2 **ALL** delegation with
`rights == 0` to the attacker — the ordinary warm-wallet / marketplace / airdrop-tool setup —
granted earlier and for an entirely unrelated purpose. The victim then binds that EOA as `ACCOUNT`.

**Mechanism.** `_hasBindingControl` step 1 (`:776-781`) falls through to
`_isAccountDelegate:861-868`, which calls `checkDelegateForAll(account, boundAddress,
DELEGATE_RIGHTS)`. Per delegate.xyz v2 semantics a rights-scoped query **also matches a blanket
`rights == 0` grant**. Because the binding is immutable, the only withdrawal is revoking the
delegate.xyz grant — outside the adapter.

**Note on the evidence, corrected during merge.** The suite establishes the two halves separately
but never the cell this attack needs. `testEmptyRightsDelegateWorks`
(`test/Adapter8004.delegate.t.sol:158-166`) proves a `rights == 0` grant satisfies a
`DELEGATE_RIGHTS`-scoped check — but at **ERC-721 scope** (`delegateERC721`).
`testAllWalletDelegateWorks` (`:177-184`) proves the wallet-wide route works — but with
**scoped `rights`**, not `bytes32(0)`. `delegateAll` *with* `rights == 0` against a scoped query,
which is the exact combination here and the most common real-world grant, is untested. It also
means the behaviour rests on the mock `delegateRegistry` faithfully reproducing delegate.xyz v2's
rights-matching rule, which is itself an unpinned assumption.

**This is the finding.** The README states the opposite in three places, and states it *as a
security property with a rationale that describes this attack*:

> `README.md:142` — "Under `ACCOUNT` (value `5`), the controller is the bound address itself, and
> only that address. **There is no holder, delegate, owner, or admin route in.**"
>
> `README.md:152` — "Only `CONTRACT_OWNABLE` has a delegate.xyz route. **`ACCOUNT` has none by
> design**: the delegator would be the bound address itself, and **a delegation it granted for any
> unrelated purpose would otherwise confer permanent control over the identity, which an immutable
> binding could never withdraw.**"
>
> `README.md:778` — lists "absence of a delegate.xyz route" among the tested `ACCOUNT` properties.

The code does the thing the README argues must not be done, for the reason the README gives.
The code comment at `:49-50` says the opposite of the README ("Delegation is accepted for …
CONTRACT_OWNABLE **and ACCOUNT**"), and the tests side with the code. `README.md:146` also
contradicts `:142`/`:152` internally by discussing revocation narrowing the `ACCOUNT` authority set.

**Falsification.** Grant `delegateAll(attacker, victim, 0, true)`; bind `ACCOUNT(victim)`; assert
`isController(agentId, attacker)` is `true`. Then decide which of README and code is wrong — that
is a product call, not a test outcome.

**Why not already covered.** `testAccountAcceptsOnlyAWalletWideDelegationRoute` and
`testAccountDelegateClaimsTheGrantorIdentityNotItsOwn` test the route as *intended behaviour*.
Nothing frames a pre-existing unrelated grant as a takeover precondition, and no test or audit
compares the README's stated guarantee against the code.

---

#### 7. A delegate.xyz grant reactivates when ownership round-trips
*Attribution: adapter only.* **Prior: likely.**

**Goal.** Regain control of an identity long after every party involved believes the delegation
lapsed.

**Preconditions.** Alice owns the bound ERC-721 and delegates to Eve. Alice sells to Bob. Later
Alice reacquires the token — buy-back, loan repayment, escrow return, vault withdrawal.

**Mechanism.** `_isERC721Delegate:884-895` is keyed on `(account, **current owner**, contract,
tokenId)`, read live on every check. A token transfer does **not** revoke the delegate.xyz grant;
it merely changes the address the adapter asks about. While Bob owns the token, Alice's grant to
Eve is irrelevant and every check denies Eve. The moment Alice is the owner again, the identical
stored grant is consulted against Alice once more and Eve silently regains full control — with no
event, no on-chain signal, and nothing in the adapter recording that it happened.

**Falsification.** Alice delegates to Eve; assert Eve controls. Transfer to Bob; assert Eve is
denied. Transfer back to Alice; assert Eve controls **again** without any new delegation.

**Why not already covered.** `testFormerOwnerDelegationStopsWorkingAfterTransfer` and
`testPriorOwnerDelegationFailsAfterTransfer` prove the *deactivation* half and stop there. No test
returns the token to the original owner. The suite documents that delegation lapses; it does not
document that it is dormant rather than dead.

---

#### 8. `ACCOUNT` bound to an undeployed CREATE2 address → deployer squat
*Attribution: seniordev only.* **Prior: plausible.**

**Goal.** Become the permanent controller of an identity the victim intended for their future
smart account.

**Preconditions.** The victim binds `ACCOUNT` to a counterfactual CREATE2 address before any code
exists there — the standard smart-account onboarding shape.

**Mechanism.** `_requireValidBoundAddress:680-690` **skips the code-length check for `ACCOUNT`**
(`:683-685`), by design, so a contract can bind itself from its own constructor. Control is
`msg.sender == boundAddress` (`:777`). Whoever first deploys *any* contract able to make an
outbound call at that address controls the identity forever, and the binding is immutable.

**Falsification.** Bind `ACCOUNT(predicted)`; have the attacker `CREATE2` a minimal forwarder
there; assert it passes `_requireController`.

**Why not already covered.** `testAccountRegistersFromCodelessAddress`,
`testAccountBindsFromItsOwnConstructorAndKeepsControlAfterward` and
`testAccountCounterfactualRegisterFromCodelessAddress` establish that codeless `ACCOUNT` binding
is *supported*. Pre-deployment squatting of that address is not tested.

---

#### 9. `_controlsAccount` is a strictly wider authority set than `ACCOUNT` binding control
*Attribution: seniordev only.* **Prior: plausible.**

**Goal.** Rewrite an `ACCOUNT`'s reverse wallet→UBID designation from an address that has zero
control over the identity itself.

**Preconditions.** The `ACCOUNT` is a contract exposing `owner()` / `getOwner()` /
`DEFAULT_ADMIN_ROLE` — most smart accounts and vaults do.

**Mechanism.** Two different authority predicates exist for one address.
`setWalletUBIDFor:523-528` and `clearWalletUBIDFor:535-538` gate on
`_controlsAccount:630-639` = *self ∪ owner() ∪ getOwner() ∪ role-0 holder*. Identity control under
`ACCOUNT` is `_hasBindingControl:776-781` = *self ∪ wallet-wide delegate*. Neither set contains the
other. So the contract's `owner()` can set and clear the account's UBID pointer while
`isController` reports them as having no authority at all.

**Falsification.** `OwnableAccount` with `owner != self`; `prank(owner)` → `setWalletUBIDFor`
succeeds while `isController(agentId, owner)` is `false`.

**Why not already covered.** `testOwnerAndDefaultAdminControlTheForSurface` and
`testNonControllerRejectedOnTheForSurface` test `_controlsAccount` in isolation. No test compares
the two predicates for the same address.

---

### C. UBID derivation and standard numbering

#### 10. Appending a standard silently routes it to the ERC-6909 branch
*Attribution: adapter only.* **Prior: plausible.**

**Goal.** A future upgrade hands control of every identity under a newly appended standard to
whoever holds an ERC-6909 balance at the bound address.

**Preconditions.** A later release appends `Standard` value `8` — which the append-only numbering
rule explicitly anticipates — without editing `_hasBindingControl`.

**Mechanism.** `_hasBindingControl:770-826` is a chain of `if`s ending in an **unconditional
fallthrough**: `return IERC6909(boundAddress).balanceOf(account, tokenId) > 0;` (`:826`). There is
no `revert` for an unhandled standard. `_isAccountStandard:830-834` and
`_isSingleOwnerStandard:836-838` are explicit allowlists, so a new account-like standard also
silently escapes `_requireCanonicalTokenId:733-737`, admitting nonzero `tokenId` and therefore a
second UBID axis the design forbids. Because `standard` is identity-critical and in the preimage,
every identity minted under the new value before the omission is noticed is permanently mis-keyed.

**Falsification.** Add a dummy ninth enum member in a test build; assert `_hasBindingControl`
denies or reverts for it rather than probing `IERC6909.balanceOf`.

**Why not already covered.** `testEnumNumberingIsPinned` and
`testAppendedContractStandardDoesNotRenumberStoredStandards` pin the *numbering* and prove
appending does not renumber stored values. Neither tests **dispatch completeness** — that every
declared standard reaches a branch written for it.

---

#### 11. Unclaimable phantom identities via `hashBinding` + `attest`
*Attribution: converged (adapter + seniordev #8).* **Prior: plausible.**

**Goal.** Seed indexers with identities that carry attacker-authored history and that **no
legitimate party can ever contest**, because no write path can emit a competing event for them.

**Preconditions.** None. Both entry points are permissionless.

**Mechanism.** `hashBinding:311-313` performs **no validation at all** — no
`_requireValidBoundAddress`, no `_requireCanonicalTokenId`. It will compute
`UBID(ACCOUNT, X, tokenId = 7)`. Every *writer* rejects that coordinate via
`_requireCanonicalTokenId:733-737`, so no `CounterfactualAgent*` event can ever name it.
`_attest:601-619` accepts any nonzero `bytes32` by design (`:605`, and the design note at
`:598-600`). The attacker can therefore accumulate an attestation history against a UBID that is
structurally unreachable by any controller — the target can never supersede it, because
supersession requires emitting an event the contract will not let anyone emit.

**Falsification.** `attest` against `hashBinding(ACCOUNT, X, 7)`; assert it succeeds, and that
every counterfactual writer and `setWalletUBID` revert `NonZeroTokenIdForAccount` for the same
coordinate.

**Why not already covered.** `testWalletUBIDRejectsCoordinatesNoClaimCanMatch` closes exactly this
hole **on the `setWalletUBID` path only**. The `hashBinding` + `attest` pair is open, and the
existing test's own name shows the property was considered worth enforcing.

---

#### 12. One UBID, many agentIds: duplicate-registration resolution ambiguity
*Attribution: adapter only.* **Prior: plausible.**

**Goal.** Make an off-chain resolver that maps UBID → registry row land on the attacker's row —
with the attacker's `agentURI` and metadata — for an identity the victim registered first.

**Preconditions.** Attacker holds any balance of the bound ERC-1155/6909 id, or is any co-holder.
For ERC-721 they need only transient ownership (compose with #3).

**Mechanism.** `_register:135-168` mints a **fresh** `agentId` per call and writes
`_bindings[agentId]` unconditionally (`:162`). Nothing prevents a second registration of the same
`(standard, boundAddress, tokenId)`. Both rows therefore satisfy
`bindingHashOf(agentId_1) == bindingHashOf(agentId_2)` (`:317-320`) — the UBID is a function of
the binding, not of the agentId. The UBID → agentId relation is one-to-many, and the contract
offers no tiebreak: no first-writer-wins, no enumeration, no `AgentBound` ordering guarantee that
a resolver is told to use. Attestations against that UBID apply to both rows simultaneously.

**Falsification.** Two holders of one ERC-1155 id each register; assert distinct `agentId`s with
identical `bindingHashOf`, and that nothing on-chain distinguishes which is canonical.

**Why not already covered.** `testFuzzDuplicate721RegisterProducesDistinctAgents` and
`test1155MultipleHoldersCanRegisterSeparateAgents` prove duplicate registration is *permitted*
and produces distinct ids. Neither asks what a UBID-keyed consumer is supposed to do with two
rows, which is where the exploitable ambiguity lives.

---

#### 13. Same-chainid fork replays every UBID and every attestation identifier
*Attribution: adapter only.* **Prior: long shot.**

**Goal.** Replay a whole attestation and claim history onto a second chain where it was never
made, or silently re-key every identity.

**Preconditions.** A chain fork that retains `block.chainid` (contentious fork, chain-clone
testnet, or an L2 stack forked with its chainid intact), with the adapter at the same address.

**Mechanism.** Both identifier schemes bind to the chain **only** through
`_interoperableAddress:924-926` → `block.chainid`. `_bindingHashFrom:961-968` and `_attest:610-614`
carry no other chain-domain field. Two chains sharing a chainid and an adapter address produce
byte-identical UBIDs and byte-identical `attestationId`s, so events from one are
indistinguishable from the other to any consumer keyed on those values. Conversely, a chainid
change re-keys every identity and orphans every attestation ever made.

**Falsification.** `vm.chainId` two environments with the same id and adapter address; assert
`hashBinding` and the emitted `attestationId` are identical across both.

**Why not already covered.** `testCounterfactualRegistrationHashChangesWithChainId` and
`testIdentifierBindsTheProxyNotTheImplementation` prove the hash *moves* with chainid and with the
proxy address — i.e. they test the axes that do vary. The same-chainid-different-chain case is the
complement and is untested.

---

### D. Counterfactual and unminted paths

#### 14. Targeted pre-claim poisoning of a marquee identity's key space
*Attribution: converged (seniordev #8 + adapter).* **Prior: plausible.**

**Goal.** Attach attacker-chosen metadata keys and history to an identity a known victim will
later own, in a form the victim cannot delete.

**Preconditions.** The target `(standard, boundAddress, tokenId)` is publicly predictable — a
known collection with a known mint schedule — and the token is not yet minted.

**Mechanism.** For a single-owner collection, `_hasNoCurrentOwner:738-746` reports an unminted id
as ownerless, opening the collection-authority route in `_requireTokenAuthority:723-729`; and
`hashBinding:311-313` plus `attest:583-585` and `setWalletUBID:515-520` are permissionless
regardless. The attacker sprays `Attested`, `WalletUBIDSet`, and — where they hold the collection
route — `CounterfactualMetadataSet` entries against the future UBID. **The key-space point is what
makes it durable:** counterfactual metadata is last-event-wins *per key*
(`counterfactualSetMetadata:395-424`). The eventual owner can overwrite key `k` only if they know
`k` exists. Any key they never enumerate still projects the attacker's value forever, and there is
no delete.

**Falsification.** Poison key `"x"` on a future UBID; mint to the victim; have the victim write
their own keys; assert an indexer replay still surfaces the attacker's `"x"`.

**Why not already covered.** `counterfactual-unminted.t.sol` establishes the unminted and
ownerless routes as *intended*, and `testMultipleOwnerlessRegistrationsUseSameHashAndLastLogWins`
covers last-log-wins for the claim. The **per-key** durability of poisoned metadata against a
later legitimate owner is not tested, and the targeted-victim framing is absent.

---

#### 15. One block of authority buys a permanent bidirectional wallet↔identity link
*Attribution: adapter only.* **Prior: likely.**

**Goal.** Manufacture a wallet↔identity association that satisfies an indexer's *strictest*
rule — both directions confirmed, same transaction, same actor — from a momentary window of
authority, and that never expires.

**Preconditions.** One transaction of token authority. Compose with #3 (flash-borrowed balance),
#1 (fabricated ownerless window), or #7 (dormant delegation).

**Mechanism.** The design splits the association in two: identity→wallet is authority-gated, and
wallet→identity is not (`_setWalletUBID:542-557` deliberately checks no token authority — only
address shape and canonical `tokenId`). Consumers are told to check the forward direction before
trusting the reverse. `counterfactualSetAgentWalletAndUBID:469-491` emits **both halves in one
transaction**: `CounterfactualAgentWalletSet` with `msg.sender` as the wallet (`:483-485`), then
`_setWalletUBID(msg.sender, …)` (`:490`). A verifier that demands both directions is satisfied by
a single call. Nothing on-chain ever re-checks, and neither event carries an expiry, so the link
survives the authority lapsing by exactly one block.

**Falsification.** Grant authority for one transaction; call
`counterfactualSetAgentWalletAndUBID`; revoke authority; assert both events stand and that a
both-directions-confirmed projection still links attacker wallet ↔ victim identity.

**Why not already covered.** `testCounterfactualCombinedRequiresTokenAuthority` proves authority
is required **at call time**, and `testCounterfactualLoopVerifiesAfterTheCombinedCall` proves the
loop closes. Neither tests what happens **after the authority goes away** — which is the whole
attack. The combined entry point is new in v0.0.17 and appears in no prior audit.

---

### E. Attestation as disinformation

#### 16. Reputation laundering: attestation history rides the bound token on resale
*Attribution: adapter only.* **Prior: likely.**

**Goal.** Buy a highly-rated agent identity's entire accumulated reputation for the price of one
NFT, or dump a poisoned identity onto a buyer.

**Preconditions.** The bound token is transferable and the identity has accumulated attestations.

**Mechanism.** The UBID is `keccak256(abi.encode(adapterIA, standard, boundAddress, tokenId))`
(`:961-968`) — a pure function of the **binding**, not of the controller. Attestations key on the
UBID (`_attest:610-614`). Selling the bound token transfers control (`_hasBindingControl:806-815`,
live) while leaving the UBID unchanged, so every `Attested` event ever made about that identity now
describes an agent under new management. There is no on-chain signal of the handover in the
attestation stream, no nonce, and no way for past attesters to scope a statement to "the entity
that controlled this at the time".

**Falsification.** Accumulate `RATING` attestations for an ERC-721-bound agent; transfer the token
to the attacker; assert the UBID is unchanged and the projection's aggregate score is intact under
the new controller.

**Why not already covered.** `attestation-projection.t.sol` is thorough on aggregation semantics
(`testRatingAggregationExcludesDependentAttesters`,
`testRatingAggregationExcludesInvalidPayloads`, revocation, re-emission). Every one of those tests
holds the controller fixed. `test721ControlFollowsTokenTransfer` covers the transfer but not its
effect on the attestation stream. The two halves are individually tested and never composed.

---

#### 17. Front-run revocation poisoning of a pending attestation
*Attribution: adapter only.* **Prior: plausible.**

**Goal.** Suppress a competitor's incoming reputation attestation in any consumer that treats a
revocation as a property of the identifier rather than of the ordered log.

**Preconditions.** Mempool visibility of the victim's pending `attest` / `confirmAdditionalAccount`.

**Mechanism.** `attestationId` is `keccak256` over entirely **public** inputs — adapter
interoperable address, `msg.sender`, `ubid`, type, `block.number`, `variant`, `data`
(`_attest:610-614`). An observer of a pending transaction knows every field, including the block
it will land in. `_revoke:623-625` "checks nothing, deliberately" and will emit
`AttestationRevoked` for any `bytes32` from any caller. The attacker computes the victim's
identifier and lands a `revoke` **earlier in the same block**. The log order is
revoke-then-attest, which a correct projection ignores — but an implementation keyed on "has this
id ever been revoked" drops a legitimate statement. `confirmAdditionalAccount:587-591` is the
easiest target because `variant` is hardcoded to `bytes32(0)`, removing the one field a victim
could randomise.

**Falsification.** Compute the victim's `attestationId` for block N; `revoke` it at a lower log
index in block N; then let the `attest` land. Assert both events exist and that ordering is the
only thing separating a correct projection from a poisoned one.

**Why not already covered.** `testNonAttesterRevocationIsIgnored` proves the *reference*
projection requires attester identity — which defeats a naive replay but says nothing about
**ordering**. `testAttestRevokeAttestRevokeEndsWithdrawn` and
`testReactivationAcrossBlocksIsANewStatement` exercise revoke-after-attest only. No test emits a
revocation *before* the attestation it names.

---

### F. Metadata and registry-side assumptions

#### 18. Registry key-normalization mismatch forges the `agent-binding` record
*Attribution: converged (both lists, independently — which is why I rate it above its individual prior).* **Prior: plausible.**

**Goal.** Forge the one metadata record only the adapter is supposed to author, so an ERC-8217
verifier resolves the agent to an attacker-chosen binding contract.

**Preconditions.** Caller controls the agent. The ERC-8004 registry normalizes metadata keys in
any way — case folding, trimming, Unicode NFC/NFKC, or truncation.

**Mechanism.** The reservation is a single exact keccak comparison:
`BINDING_METADATA_KEY_HASH` (`:46`), checked at `setMetadata:208-210`,
`counterfactualSetMetadata:413-415`, and `_requireNoReservedBindingKey:900-909`. Keys such as
`"Agent-Binding"`, `"agent-binding "` or `"agent-binding "` hash differently, pass every
adapter guard, and then collide onto the canonical key inside a normalizing registry — overwriting
the 20-byte value the adapter wrote at `_register:157`. The adapter's entire ERC-8217 guarantee
rests on an unstated assumption of **exact key identity** between itself and the registry.

**Falsification.** Normalizing registry mock; `setMetadata(agentId, "Agent-Binding", fake)`; assert
`getMetadata(agentId, "agent-binding")` returns `fake`.

**Why not already covered.** Every reserved-key test — `testRegisterRejectsReservedBindingMetadataKey`,
`testSetMetadataRejectsReservedBindingMetadataKey`,
`testSetMetadataBatchRejectsReservedBindingMetadataKey`,
`testCounterfactualSetMetadataRejectsReservedBindingMetadataKey` — submits the *exact* string and
asserts a revert. `testRegisterAcceptsCfRegistrationKey` confirms only `agent-binding` is reserved.
Grep shows **no test submits any case or whitespace variant**. The registry is now immutable and
trusted, which bounds this — but the assumption is nowhere written down as a registry requirement.

---

#### 19. Blind `setAgentWallet` signature forwarding inherits the registry's replay properties
*Attribution: seniordev only.* **Prior: plausible.**

**Goal.** Assign or grief an agent's wallet using a consent signature that was never meant for
that agent.

**Preconditions.** Caller controls agent B. The registry's wallet-consent signature is not bound
to the agent id, or is otherwise replayable.

**Mechanism.** `setAgentWallet:240-252` performs `_requireController` and then forwards
`(newWallet, deadline, signature)` **verbatim** (`:248`) with no adapter-side domain binding,
nonce, or agent-id check. Whatever replay properties the registry's EIP-712 domain has become the
adapter's. The adapter presents itself as the authority layer while adding nothing on this path.

**Falsification.** Registry mock whose wallet signature omits the agent id; controller of agent B
replays agent A's signature through `setAgentWallet(B, …)` and succeeds.

**Why not already covered.** Adapter tests exercise valid signatures through the mock only; there
is no adapter-side test for malformed, expired, or replayed wallet signatures.

---

### G. Upgrade path

#### 20. The `RegistryMismatch` guard is spoofable and has no negative test anywhere
*Attribution: converged (adapter + seniordev #12).* **Prior: long shot.**

**Goal.** Pass a hostile implementation through the check that Safe signers are told protects
against binding capture.

**Preconditions.** The Safe is socially engineered into approving an implementation address —
the same precondition any UUPS upgrade attack needs. Owner-gated, so severity is bounded; the
value here is the **false assurance**, not a privilege escalation.

**Mechanism.** `_authorizeUpgrade:665-672` calls
`Adapter8004(newImplementation).identityRegistry()` (`:669`) and compares it to its own immutable.
That return value is entirely under the control of the incoming implementation, which can return
the expected registry from that one getter while doing anything at all elsewhere. UUPS's
`proxiableUUID` check constrains the *shape* but not the semantics. The comment ties this to audit
finding G2-01 (binding capture) and the deploy script leans on it when instructing signers, so the
guard is load-bearing socially while being only a typo-catcher technically.

**Falsification.** `SpoofImpl` returning the correct registry from `identityRegistry()` and
arbitrary behaviour otherwise; assert `upgradeToAndCall` passes the guard.

**Why not already covered.** `testFuzzNobodyCanSwapRegistry` and `testFuzzNonOwnerCannotUpgrade`
cover the owner gate and the immutability of the registry. Searching the suite, **`RegistryMismatch`
has no negative test at all** — no test ever constructs an implementation with a *different*
registry and asserts the revert. The guard's happy path is untested in both directions.

---

## 3. Attribution summary

| # | Scenario | Source | Prior |
|---:|---|---|---|
| 1 | Reverting-`ownerOf`: perpetual authority + buyer lockout | converged | likely |
| 2 | `isController` is not total | adapter | plausible |
| 3 | Flash-borrowed 1155/6909 control | adapter | likely |
| 4 | `owner()` echoing `tx.origin` | adapter | plausible |
| 5 | Permissive `DEFAULT_ADMIN_ROLE` | converged | plausible |
| 6 | ACCOUNT delegate route vs README rationale | seniordev (verified by adapter) | likely |
| 7 | Delegation reactivates on ownership round-trip | adapter | likely |
| 8 | ACCOUNT CREATE2 squat | seniordev | plausible |
| 9 | `_controlsAccount` ⊋ ACCOUNT control | seniordev | plausible |
| 10 | Enum-extension fallthrough to ERC-6909 | adapter | plausible |
| 11 | Unclaimable phantom UBIDs | converged | plausible |
| 12 | UBID → agentId one-to-many | adapter | plausible |
| 13 | Same-chainid fork replay | adapter | long shot |
| 14 | Pre-claim key-space poisoning | converged | plausible |
| 15 | One block of authority → permanent link | adapter | likely |
| 16 | Reputation laundering on resale | adapter | likely |
| 17 | Front-run revocation poisoning | adapter | plausible |
| 18 | Registry key-normalization mismatch | converged (independent) | plausible |
| 19 | Blind `setAgentWallet` signature forwarding | seniordev | plausible |
| 20 | `RegistryMismatch` spoofable, no negative test | converged | long shot |

**6 likely / 12 plausible / 2 long shot.** Nine scenarios came from one reviewer and not the
other, which is the main argument that the independent-read protocol was worth the cost.

---

## 4. Where we disagreed

Recorded rather than smoothed. Four substantive items.

**4.1 Intra-transaction TOCTOU on `owner()` / `ownerOf` — seniordev raised it as a likely
disagreement; we converged against it.**
seniordev argued it is "effectively not exploitable" because the hostile contract is reached only
by `staticcall` and so cannot cheaply count calls. I agree, and can sharpen the reason: `STATICCALL`
forbids `SSTORE` *and* `TSTORE`, so a bound contract has no reliable intra-call counter — only
`gasleft()` heuristics. More decisively, the **only** place the adapter makes two `ownerOf` reads
inside one call is `_requireTokenAuthority:723-729`, and that path is reached only when
`account == boundAddress` — the collection asking about itself. A differential answer there yields
the collection nothing it does not already have via #1. **Resolved: not a scenario.** The
cross-transaction form is #1 and #7.

**4.2 UBID second-preimage across the three account standards — converged against.**
seniordev pre-emptively rejected any collision claim at `(X, 0)` across ACCOUNT /
CONTRACT_OWNABLE / CONTRACT_ADMIN. I independently reached the same conclusion: `standard` occupies
a full 32-byte word in `abi.encode` (`_bindingHashFrom:961-968`), and the adapter interoperable
address is length-prefixed as a dynamic `bytes`, so the packed-encoding collision the doc warns
about does not apply. Neither of us is claiming a collision. **Resolved: not a scenario.**

**4.3 Registry returning a duplicate `agentId` → silent rebinding. Genuine disagreement, about
priority rather than probability.**
seniordev rated it **long shot** and I do not dispute the exploitation prior — the registry is
immutable, canonical, and honest. My disagreement is that they treated the low prior as a reason to
rank it down, and I think two facts change the calculus: (a) `_register:162` writes
`_bindings[agentId]` unconditionally, so the "binding is immutable" invariant — which the README,
the interfaces, and `testFuzzBindingImmutableAcrossAllWrites` all assert — rests **entirely** on
registry id-uniqueness with no adapter-side check; and (b) the mock that proves it **already
exists**: `test/security/mocks/OverflowRegistry.sol:10-20` returns `type(uint256).max` from all
three `register` overloads, and `testOverflowRegistryCanStillRegister` calls it exactly **once**. A
second call in that existing test would demonstrate the rebind. Guard is one line, test is two.
I did not use one of the twenty slots on it because I agree it is not an attack anyone can mount
today — but I think it should be fixed on defence-in-depth grounds regardless of prior, and I am
recording that as an open disagreement rather than resolving it by fiat.

**4.4 Inclusion threshold for pure griefing. Mild, unresolved, low stakes.**
seniordev considered `onERC721Received:293-296` accepting any NFT with no sweep and no
`_bindings` entry, and deliberately left it off their numbered list as "pure griefing/asset-lock,
not identity theft." I agree with the classification and also left it out of the twenty, so there
is no practical difference — but for the record I would rather see permanent-custody asset locks
tracked somewhere than dropped, since the adapter is a permanent on-chain owner by design and this
is the one path where that property is reachable by a stranger. Same applies to duplicate-registration
id-space spam, which seniordev also cut.

**Non-disagreement worth noting:** #18 (registry key normalization) was derived independently by
both of us from different starting points. That is the strongest single signal in this exercise,
and it is why I rate it above where either of us placed it alone.

---

## 5. Considered and cut

Cut because an existing test already covers them — recorded so the next pass does not re-derive them:

- **Owner-flip by a hostile ERC-721.** `testMaliciousERC721CanFlipControl` covers it directly.
  Survives only in the reverting-rather-than-flipping form, which is #1.
- **Post-burn re-claim by the collection.** `testBurnReopensOnlyCollectionOwnerlessWindow` covers
  the window and that a stranger cannot use it.
- **View-time reentrancy through `ownerOf` / `balanceOf`.** Three explicit tests
  (`testMaliciousERC721ReentryIsBlockedByStaticcall` and the 1155/6909 equivalents), plus
  `testOwnerOfCannotReenterUnsignedCounterfactualWrite`.
- **Proxy-vs-implementation UBID divergence.** `testIdentifierBindsTheProxyNotTheImplementation`.
- **Non-attester revocation.** `testNonAttesterRevocationIsIgnored`. Survives only in the
  *ordering* form, which is #17.
- **Malformed / dirty `owner()` and `ownerOf` returns.** `testDirtyAndWrongLengthOwnerResponsesFailClosed`,
  `testMalformedSuccessfulOwnerOfResponsesFailClosed`, `testOverlongOwnerResponseFailsClosedOnLengthAlone`.
- **Reinitialization of a live proxy.** `testCannotReinitializeProxy`,
  `testImplementationInitializerIsDisabled`.

Cut, from seniordev's list, so that all sixteen of their items are accounted for:

- **seniordev #1 — `isController` is a point-in-time snapshot that a legitimately dynamic
  `owner()` / `hasRole` makes lie across transactions.** Real, and correctly identified as an
  oracle-vs-action gap rather than a bug. Cut as a standalone because it is the *passive* form of
  what #3 weaponises: an attacker who wants the divergence does not wait for a rotating multisig,
  they manufacture it with a flash-borrowed balance inside one block. Retained here because the
  general property — **every authority read is live and valid only in its own block, and the
  contract offers consumers no snapshot, nonce, or as-of primitive** — is worth stating once in
  the integration docs even though it is not itself an attack.
- **seniordev #6 — backdoored / reclaimable `CONTRACT_OWNABLE`.** Cut because it is the
  documented model rather than a defect: `README.md:143` defines `CONTRACT_OWNABLE` authority as
  the contract's *current* `owner()`, and `_currentContractOwner:840-857` is read live on every
  check by design. `test/Adapter8004.ownable-delegate.t.sol` already has a mock with both
  `transferOwnership` and `setOwner` (`:24`, `:28`), and
  `testOwnableAuthorityFollowsTransferAndOldOwnerLosesControl` pins the live-read semantics. A
  "reclaim" is just another `transferOwnership`. The residual risk is that a buyer cannot tell an
  honest Ownable from a backdoored one — a diligence problem, not a contract weakness.
- **seniordev #9 — `confirmAdditionalAccount` reciprocal-half time-window spoof.** Real and
  distinct from #15 (theirs turns the forward half *off* after confirming; #15 never has durable
  authority in the first place). Cut only for slot budget, and it is the strongest of the three
  cuts here: if a twenty-first slot existed it would take it. Same root cause as #15 — the
  reciprocal handshake is two independent emit-only projections with no on-chain join and no
  expiry — so fixing #15 properly should cover it.

Cut on judgement, with the reason:

- **`ReentrancyGuard` storage collision in an upgradeable contract.** I checked this specifically
  because the contract inherits the **non**-upgradeable `ReentrancyGuard`. It is safe: this OZ
  version uses a namespaced slot (`_reentrancyGuardStorageSlot()`,
  `lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:116-118`), which
  `forge inspect Adapter8004 storageLayout` confirms by showing only `__deadRegistrySlot`@0 and
  `_bindings`@1. Worth stating because seniordev's OZ-storage-regression item depends on this
  remaining true across submodule bumps, and nothing in CI pins it.
- **Attestation payload non-validation** (seniordev #10) — real and correctly identified as a
  deliberate trust boundary; belongs in the spec as an explicit consumer requirement rather than
  in an attack list.
- **Uninitialized-proxy seizure** — depends on a proxy being deployed with empty init data, which
  the documented deploy flow does not do. Catastrophic if it ever happened; procedural, not a
  contract weakness.
- **Delegate registry carrying wrong code on a new chain** (seniordev #14) — the deterministic
  deployment constrains what can land at that address; relevant only for chains beyond the current
  Mainnet/Base/Sepolia set.

---

## 6. Recommended next step

If execution is approved, the three cheapest high-information tests are, in order:

1. **#6** — one `delegateAll` + one bind + one `isController` assertion settles whether the README
   or the code is wrong about `ACCOUNT`. This is a documentation-vs-code contradiction on a
   security property, and it needs a product decision, not just a test.
2. **#20 / §4.3** — both are missing *negative* tests against mocks that already exist
   (`RegistryMismatch` has none at all; `OverflowRegistry` needs one extra call).
3. **#1 and #2** — a single `RevertingOwnerOf721` mock exercises both the authority-granting and
   the `isController`-totality halves of the same asymmetry.
