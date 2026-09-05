# Adapter8004 v0.0.17 — Grok execution of the six "likely" scenarios

Independent cross-model run against `/Users/nxt3d/projects/adapter-0.0.17` (`src/Adapter8004.sol` `@custom:version 0.0.17`). No `src/` edits. No existing-test edits. Only new files under `test/security/GrokExploit_*.t.sol`.

`forge test`: **410 passed, 0 failed**. Pre-existing **401** still green. **9** new tests on top (6 exploit PoCs + 3 companion defense/boundary tests).

Calibration note: all six claimed *mechanisms* are real. That is not six contract bugs. Four of them (#3, #6, #7, #16) are the published live-authority / ERC-8217 model. One (#15) is emit-only last-event-wins, with the "permanent" claim overstated. One (#1) is a real adapter-side asymmetry. Disagreements with the Claude priors are the load-bearing output of this pass.

---

## #1 Reverting-`ownerOf` collection — perpetual self-authority over sold tokens

**Verdict: EXPLOITABLE** (counterfactual + `register` paths). Registered `setAgentURI` / `_requireController` is bricked for *everyone*, including the collection.

**Test:** `test/security/GrokExploit_1_RevertingOwnerOf.t.sol`
`test_exploit_collectionKeepsCounterfactualAuthorityAfterSale`

**Success condition:** after a real mint to `buyer`, the collection fabricates ownerlessness and still drives counterfactual writers and a second `register`, while `isController(buyer)` reverts.

**What happened.** The collection stored `realOwner[tokenId] = buyer`, then flipped `ownerOf` to revert `FabricatedOwnerlessness`. While `ownerOf` still returned the buyer, the collection was denied with `NotController(collection, type(uint256).max)`. After the revert flip:

- `counterfactualSetAgentURI` and `counterfactualSetMetadata` succeeded as the collection.
- `register` succeeded a second time, minting a distinct `agentId` with the same UBID as the buyer's row.
- `isController(agentId, buyer)` reverted `FabricatedOwnerlessness` (not `false`).
- Buyer `setAgentURI` reverted `FabricatedOwnerlessness`.
- Collection `setAgentURI` on the registered agent *also* reverted `FabricatedOwnerlessness`.

**Mechanism.** `_hasNoCurrentOwner` (`Adapter8004.sol:744-748`) treats a reverting `ownerOf` as "no current owner". `_requireTokenAuthority` (`:727-729`) then grants the collection itself the ownerless window, which is the gate for `register` and every unsigned counterfactual writer. `_hasBindingControl` for single-owner standards (`:807-808`) calls `ownerOf` *unwrapped*, so the same revert propagates out of `isController` (`:279-289`) and `_requireController` (`:691-698`). That is why the collection keeps the emit-only / register surface and why the registered write surface locks both sides.

**Claude prior: likely. AGREES on the mechanism, DISAGREES on scope.** They wrote "drive every counterfactual writer" (true) and implied perpetual authority over the sold identity in general. The registered management path is *not* in that set: the collection cannot `setAgentURI` either. The durable gain is (a) unbounded counterfactual event spam against the sold UBID, (b) a second registry row sharing that UBID, (c) buyer `isController` reverting instead of returning `false`.

This is the one scenario I would file. It is the same trust boundary as the documented hostile-`ownerOf` owner-flip tests, with a worse shape: revert-as-authority-grant for the collection, revert-as-lockout for the buyer.

---

## #3 Flash-borrowed 1155/6909 control — rewrite state with 1 wei transient balance

**Verdict: EXPLOITABLE as live-control.** Not a missed snapshot. Not a finding I would file.

**Test:** `test/security/GrokExploit_3_FlashBorrowedControl.t.sol`
- `test_exploit_flash1155RewritesUriWithOneWei`
- `test_exploit_flash6909RewritesUriWithOneWei`

**Success condition:** 1 wei of flash-borrowed balance rewrites `agentURI`; attacker ends the transaction with a zero balance.

**What happened.** A pool flash-lent 1 unit of the bound id to a borrower. Inside the callback the borrower called `setAgentURI` and repaid. After the transaction: URI was `ipfs://flash-pwned` / `ipfs://flash-6909-pwned`, borrower balance 0, pool repaid, `isController(borrower)` false, long-term holder still in control.

**Mechanism.** `_hasBindingControl` steps 5 and 6 (`:820-826`) are `balanceOf(account, tokenId) > 0`. There is no holding period, snapshot, or majority check. A current holder of 1 wei is a full controller for that call. The URI write lands in the registry and survives repayment. That is the same rule `test1155ControlIsAnyCurrentHolder` already pins; the flash wrapper only shows it is usable intra-transaction.

**Claude prior: likely. DISAGREES that this is a contract defect.** The prior treats absence of a snapshot as a hole. The published model is live `balanceOf > 0` for any current holder. Flash is a current holder. A guard that stopped this would stop every honest 1155/6909 holder too. No revert fires because the caller *is* authorized at the moment of the write.

---

## #6 ACCOUNT delegate route — pre-existing blanket `delegateAll` at bind

**Verdict: EXPLOITABLE (substance: yes, they can).** Intended UX footgun, not a code bug. Narrower grants are DEFENDED.

**Test:** `test/security/GrokExploit_6_AccountBlanketDelegate.t.sol`
- `test_exploit_preexistingBlanketDelegateAllSeizesAccountAtBind`
- `test_defense_unrelatedContractScopedGrantDoesNotSeizeAccount`

**Success condition (exploit):** a `delegateAll` granted for an unrelated purpose, `rights == 0`, lets the grantee control an `ACCOUNT` identity from the moment the victim binds.
**Success condition (defense):** a contract-scoped grant for an unrelated marketplace does not.

**What happened.**

1. `delegateAll(attacker, victim, 0, true)` *before* bind. Victim binds `ACCOUNT(victim)`. `isController(agentId, attacker)` is `true`. Attacker `setAgentURI` succeeds (`ipfs://seized`).
2. `delegateContract(attacker, victim, marketplace, 0, true)` *before* bind. After bind, `isController(attacker)` is `false`. Attacker `setAgentURI` reverts `NotController(attacker, agentId)`.

**Mechanism.** `_hasBindingControl` for `ACCOUNT` (`:776-780`) falls through to `_isAccountDelegate` (`:862-867`), which calls `checkDelegateForAll(account, boundAddress, DELEGATE_RIGHTS)`. The mock (and delegate.xyz v2) treats a `rights == 0` ALL grant as matching a scoped query. README.md:142 and :152 now describe this route as intended and revocable; :152 names the blanket-grant UX footgun explicitly. `DELEGATE_SECURITY_REVIEW.md` DEL-02 already classified empty/full-rights widening as UX-only (the dispatch brief cited DEL-04; that item is about `updatedBy` attribution — the blanket-grant classification is DEL-02).

**Claude prior: likely. DISAGREES on the finding class.** Do not re-report a README/code contradiction — the docs now match the code. The substance they asked for is confirmed: a pre-existing wallet-wide `delegateAll(rights=0)` *does* confer ACCOUNT control at/after bind, with no new grant. It is the grant the victim already made, read live, and they can revoke it outside the adapter. Contract- and token-scoped grants do not seize ACCOUNT; that boundary holds.

---

## #7 Delegation reactivates on round-trip

**Verdict: EXPLOITABLE (dormant grant reactivates).** DEFENDED against acting while a later owner holds the token. Not an adapter bypass.

**Test:** `test/security/GrokExploit_7_DelegationRoundTrip.t.sol`
`test_exploit_delegationReactivatesWhenTokenReturnsToOriginalOwner`

**Success condition:** Eve is denied while Bob owns, then controls again when the token returns to Alice, with no new delegation.

**What happened.** Alice delegated to Eve; Eve controlled. Transfer to Bob: `isController(eve)` false; Eve `setAgentURI` reverts `NotController(eve, agentId)`. Transfer back to Alice with the same grant still recorded: `isController(eve)` true; Eve `setAgentURI` writes `ipfs://eve-after-roundtrip`.

**Mechanism.** `_isERC721Delegate` (`:884-897`) asks delegate.xyz about `(account, **current owner**, contract, tokenId)` live. A transfer does not revoke the grant; it changes the owner the adapter queries. While Bob owns, Alice's grant to Eve is irrelevant. When Alice is owner again, the identical stored grant matches again.

**Claude prior: likely. DISAGREES that this is an adapter attack.** Bob's window is actually defended — that is the property `testPriorOwnerDelegationFailsAfterTransfer` already covers. Reactivation is Alice's still-live delegate.xyz grant doing what it always does for the current owner. The adapter does not cache grants and has no transfer hook into delegate.xyz (it cannot). If Alice does not want Eve back, she revokes. There is no on-chain event from the adapter on the return because control is a view, not a state write.

---

## #15 One block of authority → permanent bidirectional wallet↔identity link

**Verdict: EXPLOITABLE for the one-tx closed loop; DISAGREES that it is permanent.**

**Test:** `test/security/GrokExploit_15_OneBlockPermanentLink.t.sol`
- `test_exploit_oneBlockOfAuthorityEmitsBothDirectionsThenLapses`
- `test_defense_longTermHolderCanSupersedeForwardHalfOnly`

**Success condition (exploit):** a one-transaction flash of 1 wei emits both halves of the loop; after repayment the attacker has no live control and both events still stand.
**Success condition (defense):** the long-term holder can overwrite the forward half; they cannot clear the attacker's reverse pointer.

**What happened.** Flash-borrower called `counterfactualSetAgentWalletAndUBID` and repaid. Logs contained `CounterfactualAgentWalletSet` (identity → attacker) and `WalletUBIDSet` (attacker → identity). Follow-up `counterfactualSetAgentURI` from the borrower reverted `NotController(borrower, type(uint256).max)`. Alice then called the combined function herself: forward wallet became Alice. Alice `clearWalletUBIDFor(borrower)` reverted `NotAccountController(borrower, alice)`.

**Mechanism.** `counterfactualSetAgentWalletAndUBID` (`:469-491`) requires token authority (`:479-480`), then emits the forward wallet event with `msg.sender` as the wallet (`:483-485`) and calls `_setWalletUBID(msg.sender, …)` (`:490`). `_setWalletUBID` (`:542-557`) checks address shape and canonical `tokenId` only — no token authority, by design. Both records are logs. After authority lapses the attacker cannot emit a newer forward event; a current controller can. The reverse half is the attacker's own wallet designation (`setWalletUBID` is similarly ungated for `msg.sender` even without the combined helper).

**Claude prior: likely. DISAGREES on "permanent" and "never expires".** The 1-block closed loop is real and the events persist, so a naive both-directions-confirmed indexer that does not re-check live authority will keep the attacker's link until a later forward event. Last-event-wins lets the long-term holder supersede the forward half. The reverse half was never identity-gated. Nothing here writes the ERC-8004 registry wallet; it is emit-only. I would not file this as a contract bug. I would tell indexers: do not treat a historical both-directions pair as live without a current-authority check, which the interface comment on `setWalletUBID` already says.

---

## #16 Reputation laundering — buy an identity's attestation history with the NFT

**Verdict: EXPLOITABLE as ERC-8217 semantics. Not a defect.**

**Test:** `test/security/GrokExploit_16_ReputationLaundering.t.sol`
`test_exploit_buyingTheNftBuysTheAttestationHistory`

**Success condition:** after the bound ERC-721 is sold, the UBID is unchanged and the prior `RATING` attestations still name that UBID under the new controller.

**What happened.** Two raters attested 90 and 80 against Alice's UBID. Alice transferred the NFT to the attacker. `bindingHashOf(agentId)` was unchanged. Attacker became controller; Alice `setAgentURI` reverted `NotController(alice, agentId)`. Both ratings still keyed on the same UBID; projected average 85.

**Mechanism.** UBID is `keccak256(abi.encode(adapterIA, standard, boundAddress, tokenId))` (`:961-968`). Attestations key on that UBID (`_attest:610-614`). Control follows the live token (`:806-815`). Selling the token transfers control and leaves the identifier — and therefore every `Attested` event — pointing at the same identity.

**Claude prior: likely. DISAGREES that this is an attack on the contract.** The identity *is* the binding. Buying the bound token buys the identity, including its attestation stream. There is no handover event in the attestation log because attestations are statements about a UBID, not about a controller. A guard that re-keyed UBID on transfer would break ERC-8217. Consumers that need controller-scoped reputation have to bind statements to a controller (or a nonce the adapter does not have). That is a projection/product choice, not a missed require.

---

## Disagreements with the Claude priors (the point of this pass)

All six *mechanisms* confirmed. I do not rubber-stamp six bugs.

| # | Claude prior | Grok verdict | Disagree? |
|---:|---|---|---|
| 1 | likely, perpetual authority over sold tokens | EXPLOITABLE on CF/`register`; registered writes bricked for both sides | **Yes, on scope.** They overstated "every writer". |
| 3 | likely, missing snapshot | EXPLOITABLE as live `balanceOf > 0` | **Yes.** Intended model, not a hole. |
| 6 | likely, README contradiction + instant takeover | EXPLOITABLE as intended UX; contract-scoped grants DEFENDED (`NotController`) | **Yes.** Docs now match; DEL-02 already called this UX. Substance of the grant: confirmed. |
| 7 | likely, silent regain of control | EXPLOITABLE as dormant grant; Bob's window DEFENDED (`NotController`) | **Yes.** Not an adapter bypass. |
| 15 | likely, permanent bidirectional link | EXPLOITABLE as one-tx logs; forward half overwritable | **Yes, on "permanent".** |
| 16 | likely, reputation laundering | EXPLOITABLE as ERC-8217 identity transfer | **Yes.** Buying the token is supposed to buy the identity. |

The only scenario I would file from this set is **#1**, as a hostile-collection trust-boundary issue with a worse shape than the existing owner-flip tests: revert opens the ownerless window instead of failing closed, and `isController` is not a total function for that binding.

---

## Test inventory

| File | Tests |
|---|---|
| `test/security/GrokExploit_1_RevertingOwnerOf.t.sol` | 1 |
| `test/security/GrokExploit_3_FlashBorrowedControl.t.sol` | 2 |
| `test/security/GrokExploit_6_AccountBlanketDelegate.t.sol` | 2 |
| `test/security/GrokExploit_7_DelegationRoundTrip.t.sol` | 1 |
| `test/security/GrokExploit_15_OneBlockPermanentLink.t.sol` | 2 |
| `test/security/GrokExploit_16_ReputationLaundering.t.sol` | 1 |
| **New total** | **9** |
| Pre-existing | 401 passing |
| Full suite | 410 passing, 0 failed |
