# Adapter8004 v0.0.17 — seniordev round 3 (20 new scenarios)

Round 3 of the adversarial audit, by `seniordev` (a different model than the Grok rounds 1–2).
None of these restates a round-1 (`output/attack-scenarios-v0.0.17.md` + `test/security/GrokExploit_*`)
or round-2 (`output/grok-round2-v0.0.17.md` + `test/security/GrokR2_*`) mechanism.

`forge test`: **473 passed, 0 failed**. Prior **453** still green. **20** new tests this pass
(`test/security/SdR3_*.t.sol`). No `src/` or existing-test changes.

Standing rules applied (a mere revert is accepted; a hostile/mutable bound token or a hostile
registry making the adapter do X is defended-by-design; a real finding = wrong bool / state
corruption / forged reserved record / believable forged attestation / real UBID collision or
capture). Line refs are into `src/Adapter8004.sol` unless noted.

**Findings: 0.**

Under-looked areas mined this round: event/log semantics an indexer relies on (emitter/provenance,
duplicate-key supersession, last-event-wins races, same-block re-emit), delegate.xyz edges across the
five delegating standards (ERC1155F/6909F ownerOf-profile reusing the ERC-721 check, contract-scope
folding wallet-wide grants, non-transitive subdelegation), registry trust corners (foreign default
wallet, tokenURI passthrough, agent-bound wallet signatures, reentrancy into the unguarded surface),
economic/gas griefing (uncapped attest data, unbounded batch loop), and upgrade edges beyond R2.

---

## 1. DelegateProfileConfusion — `SdR3_1`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 delegate items were ACCOUNT-blanket (#6) and ownership round-trip (#7); R2 had
none. No prior test drives an ERC-721-scoped grant against an ERC-1155F binding.
**Mechanism.** The ERC-1155F/6909F single-owner path resolves control via `_isERC721Delegate`
(`:807-816` → `:884-898`), i.e. the ERC-721 delegate check. A delegate.xyz grant registered at
`(contract, tokenId)` therefore governs an ERC-1155F binding at the same coordinate.
**Assessment.** This is the same coordinate the owner delegated; delegate.xyz keys are
`(from, contract, tokenId)` with no token-type axis, so the "F" profile correctly consults the
per-token grant. Not a wrong bool — the grantee is a legitimate delegate of that exact token.

## 2. OwnableWalletWideDelegate — `SdR3_2`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #6 is the ACCOUNT route via `checkDelegateForAll`; this is the CONTRACT_OWNABLE
route via `checkDelegateForContract` folding a whole-wallet grant.
**Mechanism.** `_isOwnerDelegate` (`:872-879`) calls `checkDelegateForContract`, which by v2 semantics
folds in an ALL (wallet-wide) delegation from the owner. An owner's unrelated wallet-wide grant thus
confers CONTRACT_OWNABLE control. Control leg: a token-scoped grant does NOT (checkDelegateForContract
ignores token-level).
**Assessment.** Documented v2 behavior; the delegator is the current owner acting deliberately. Same
class of "wallet-wide grants are broad" caution as R1 #6 but on a different standard/route.

## 3. SubdelegationNotTransitive — `SdR3_3`
**Verdict: DEFENDED.**
**Why not R1/R2:** no prior scenario probes a delegate-of-a-delegate chain.
**Mechanism.** Every adapter delegate check names the current owner as `from` (`:815`, `:794`,
`:867`). A grant whose `from` is the first-hop delegate matches nothing, so authority is not
transitive.

## 4. UnboundedAttestDataGrief — `SdR3_4`
**Verdict: DEFENDED (economic).**
**Why not R1/R2:** no prior scenario tests calldata/log-size economics.
**Mechanism.** `attest` (`:582-619`) caps neither `data` nor `variant`; a 40 KB payload is emitted.
Griefing of indexer/log storage, but the attacker pays the calldata gas and nothing is corrupted.

## 5. UnboundedBatchLoopGrief — `SdR3_5`
**Verdict: DEFENDED (economic).**
**Why not R1/R2:** no prior scenario tests batch-loop economics.
**Mechanism.** `setMetadataBatch` (`:222-238`) loops over caller entries with no length bound. Only
the caller pays; no other party is griefed.

## 6. BatchDuplicateKeySupersession — `SdR3_6`
**Verdict: DEFENDED.**
**Why not R1/R2:** R2 #3 tested batch reserved-key atomicity; none tests duplicate-key supersession
vs event ordering.
**Mechanism.** The loop (`:233-237`) writes+emits each entry in order; a repeated key emits two
`MetadataSet` logs while the registry keeps the last value. On-chain state is last-write-wins and
consistent; a first-occurrence indexer is a consumer bug.

## 7. RegistryReentrantAttest — `SdR3_7`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R2 #12 reentered a GUARDED function (`setAgentURI`) and was blocked; this reenters
the UNGUARDED emit-only surface and is not.
**Mechanism.** `attest`/`revoke`/`setWalletUBID` are deliberately not `nonReentrant` (`:566-568`), so
a registry can reenter `attest` while the adapter holds its `register` guard. The reentrant attester
is truthfully the registry (`msg.sender`), not the adapter — no impersonation, no adapter-state
corruption, and the registry is immutable/trusted.

## 8. RegistrarEmitterSkew — `SdR3_8`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #16 was reputation-on-resale; none inspects the `registeredBy`/`emitter`
provenance field.
**Mechanism.** `AgentBound.registeredBy` is `msg.sender` (`:171`). A delegate.xyz delegate (not the
owner) may register, so the field records the delegate. Documented as the caller; the delegate is a
legitimate controller. An indexer equating `registeredBy` with the owner is misled — a consumer
assumption, not a contract defect.

## 9. CounterfactualWalletUnconsentedAssoc — `SdR3_9`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #15 used the caller as the wallet in the combined AndUBID path; this is the
arbitrary-`newWallet` single setter.
**Mechanism.** `counterfactualSetAgentWallet` (`:451-467`) lets a controller name any `newWallet`
with no consent (unlike on-chain `setAgentWallet`, which the registry gates with a wallet signature).
The interface documents this as an unverified off-chain claim consumers must confirm via the reverse
(WalletUBID) direction, so it is disinformation only against a consumer who skips that check.

## 10. SameBlockReemitAfterRevoke — `SdR3_10`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #17 was a stranger revoking BEFORE the attest (ordering); R2 #15 was
type-in-preimage. Neither re-emits an identical statement after revoking it within one block.
**Mechanism.** `attestationId` includes `block.number` and `variant` (`:610-614`). Attest, self-
revoke, then re-attest identical fields in one block reproduce the same id (attested-revoked-attested
with only log order to resolve). Correct projection uses log order; the attester can force a fresh id
via `variant` — proven in-test.

## 11. MultiHolderMetadataLastWins — `SdR3_11`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #14 was pre-claim poisoning by one actor; none tests two concurrent legitimate
holders racing the same key.
**Mechanism.** Plain ERC-1155 control is any positive balance (`:820-822`); two co-holders can both
emit `CounterfactualMetadataSet` for one UBID/key, resolved only by log order. Multi-holder control is
the documented ERC-1155 model.

## 12. ConfirmRevokeToggle — `SdR3_12`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #9 toggled the FORWARD metadata half; R1 #17 was a stranger revoking. This
toggles the confirm half itself by its own attester.
**Mechanism.** `confirmAdditionalAccount` emits a CONFIRM_ACCOUNT attestation (`:587-591`); the same
attester later revokes its own deterministic id (`:594-596`). A point-in-time indexer sampling the
"on" interval is misled; a correct projection applies the revoke in log order.

## 13. CrossAttesterIdForgeryBlocked — `SdR3_13`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #17 concerned ordering of a stranger's revoke; none proves cross-attester id
forgery impossible.
**Mechanism.** `attestationId` binds `msg.sender` (`:610-614`), so identical fields under two
attesters yield different ids; an attacker cannot grind an id equal to a victim's to have their own
revoke withdraw it.

## 14. UpgradeToCodelessImpl — `SdR3_14`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #20 used a live impl with a lying getter; R2 #10/#11 covered reinit and dead
slot 0. None points the guard at a non-contract.
**Mechanism.** `_authorizeUpgrade` calls `Adapter8004(newImplementation).identityRegistry()` (`:670`);
a codeless target makes that high-level call revert, so the upgrade cannot land. Proxy unchanged.

## 15. WalletSigAgentBound — `SdR3_15`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #19 flagged the sig forwarding as untested; no test attempts the cross-agent
replay.
**Mechanism.** `setAgentWallet` forwards `(newWallet, deadline, signature)` verbatim (`:248`). The
registry binds `agentId` (and `owner = ownerOf = adapter`) into its EIP-712 struct hash, so a
signature valid for agent A reverts (`invalid wallet sig`) when replayed onto agent B. The adapter
inherits the registry's (agent-bound) domain; against the production registry that closes the replay.

## 16. TokenURIUnboundPassthrough — `SdR3_16`
**Verdict: DEFENDED.**
**Why not R1/R2:** R2 #5 checked `ownerOf`/`isController`/`bindingOf` skew on an unbound id; it did not
contrast a truthful `tokenURI` passthrough against a reverting `bindingOf`.
**Mechanism.** `tokenURI` forwards to the registry with no binding check (`:186-188`), returning real
data for a directly-registered identity (no `agent-binding` record), while `bindingOf` reverts
`UnknownAgent`. The view forwarders are intentionally binding-agnostic; authority/binding views are
not. A consumer treating adapter `tokenURI` as proof of an adapter binding is misled.

## 17. ClearWalletUBIDForCoauthorityGrief — `SdR3_17`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #9 compared the `_controlsAccount` set to ACCOUNT binding control; none tests
one co-authority undoing another's designation.
**Mechanism.** `clearWalletUBIDFor` authorizes against `_controlsAccount` (`:535-538`), which includes
the account's `owner()`, so a co-authority can wipe a designation the account set for itself. The
interface documents that any authorized party may undo any other's designation; a stranger reverts
`NotAccountController`.

## 18. ReservedKeyIntegrityAfterAdjacentWrites — `SdR3_18`
**Verdict: DEFENDED.**
**Why not R1/R2:** R1 #18 / R2 #13 tested normalization/empty-key variants (revert or different slot);
none asserts the canonical value's integrity after legitimate adjacent-key writes.
**Mechanism.** The guard is one exact keccak (`:210`, `:46-47`). After writing `agent-binding-x` and
`binding`, `getMetadata(agentId,"agent-binding")` is still the 20-byte adapter address, and the exact
reserved key still reverts `ReservedMetadataKey`. Unshadowable by non-equal keys.

## 19. AgentWalletDefaultCleared — `SdR3_19`
**Verdict: DEFENDED.**
**Why not R1/R2:** R2 #19 checked the unset happens on the metadata overload; none tests a registry
that seeds a NON-adapter default wallet.
**Mechanism.** Step 7 (`:167-168`) unconditionally calls `unsetAgentWallet`. A `ForeignWalletRegistry`
that seeds a foreign default wallet at register still ends at `address(0)` after `register`; the
adapter does not trust or read the default's value, it zeroes it.

## 20. CounterfactualControlOscillation — `SdR3_20`
**Verdict: DEFENDED-BY-DESIGN.**
**Why not R1/R2:** R1 #7 was delegation reactivation; R1 #16 was attestation reputation on resale;
none drives repeated counterfactual metadata overwrites across ownership oscillation with a denied
write in between.
**Mechanism.** Counterfactual authority is the current owner (`_requireTokenAuthority:718-731`), and
metadata is last-event-wins per UBID. Across A→B→A the current owner overwrites the same key each
time and the former owner is denied (`NotController`) mid-cycle; the re-acquiring owner overwrites
again. Control tracks live ownership; last-event-wins is the documented projection.

---

## Tally

| Verdict | Count |
|---|---|
| DEFENDED | 12 (#3,4,5,6,10,12,13,14,15,16,18,19) |
| DEFENDED-BY-DESIGN | 8 (#1,2,7,8,9,11,17,20) |
| FINDINGS | 0 |

New tests: **20** (`test/security/SdR3_1..20`). Full suite: **473 passing**.

## Consumer-facing cautions surfaced (not contract findings)
Three recurring non-defects worth one line in integration docs, all consequences of an emit-only,
consumer-interpreted design: (a) provenance fields (`registeredBy`, counterfactual `emitter`,
counterfactual `newWallet`) are self-asserted by the caller and must not be trusted as ownership;
(b) attestation/metadata state is log-order last-event-wins, so any projection must key on log order
and attester identity, never on "id ever revoked"; (c) view forwarders (`tokenURI`, `getMetadata`,
`getAgentWallet`) are binding-agnostic — use `bindingOf`/`bindingHashOf`/`isController` to establish an
adapter binding. These echo the round-1/round-2 conclusion: the contract is sound; the residual risk
lives entirely in consumer interpretation of an intentionally permissive event surface.
