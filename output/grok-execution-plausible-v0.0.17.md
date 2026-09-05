# Adapter8004 v0.0.17 — Grok execution of the twelve "plausible" scenarios

Independent cross-model run against `/Users/nxt3d/projects/adapter-0.0.17`. No `src/` edits. No existing-test edits. New files only under `test/security/GrokExploit_*.t.sol`.

`forge test`: **429 passed, 0 failed**. Pre-existing **401** still green. Earlier likely-pass **9** still green. **19** new tests this pass.

Rule carried from the likely pass: a hostile or mutable bound token that then makes the adapter do X is **DEFENDED-BY-DESIGN**, not a finding. A mere `isController` revert is accepted. A finding would be a **wrong bool**, **state corruption**, or a **forgeable reserved record**.

None of the twelve produced a wrong bool, a rebound first row, or a forged `agent-binding`. All twelve are DEFENDED or DEFENDED-BY-DESIGN.

---

## #2 `isController` is not a total function

**Verdict: DEFENDED-BY-DESIGN** (accepted revert). No wrong bool.

**Test:** `test/security/GrokExploit_2_IsControllerNotTotal.t.sol`

**Success condition (finding):** after an honest burn, `isController` returns a bool — true for the attacker or false for the previous owner — rather than reverting.

**What happened.** After burn, both `isController(attacker)` and `isController(previous owner)` revert `Burnable721.Nonexistent(1)`. A `staticcall` returns `ok = false`; there is no decoded bool at all. A reverting ERC-1155 `balanceOf` reverts `AlwaysReverts` on `register`, never returns true. An honest live ERC-721 returns owner `true` and stranger `false`. Unknown agents still return `false` (`:284-286`).

**Mechanism.** Single-owner `_hasBindingControl` (`:807-808`) calls `ownerOf` unwrapped. ERC-1155/6909 (`:821`, `:826`) call `balanceOf` unwrapped. Those probes revert instead of failing closed to a bool. That is the accepted single-owner rule, not `true` for an attacker.

**Claude prior: plausible. DISAGREES.** Non-totality is real and already accepted. It does not turn into a wrong bool.

---

## #4 `owner()` echoing `tx.origin`

**Verdict: DEFENDED-BY-DESIGN** (trust boundary of `CONTRACT_OWNABLE`).

**Test:** `test/security/GrokExploit_4_TxOriginOwner.t.sol`

**Success condition (finding):** an honest Ownable reports `bob` as controller because `bob` is `tx.origin`.

**What happened.** Honest `owner()` stored as alice: `prank(bob, bob)` still gives `isController(bob) = false`. A contract that returns `tx.origin` from `owner()` does make every self-caller look in control — that is the bound contract lying to `_currentContractOwner` (`:842-857`), which accepts any single clean address word.

**Claude prior: plausible. DISAGREES** that this is an adapter forge. You trusted `owner()`. A hostile `owner()` is the #1 class.

---

## #5 Permissive `DEFAULT_ADMIN_ROLE`

**Verdict: DEFENDED** against an honest AccessControl identity. Fallback / public-grant contracts are **DEFENDED-BY-DESIGN**.

**Test:** `test/security/GrokExploit_5_PermissiveAdminRole.t.sol`

**Success condition (finding):** a stranger seizes an honestly admin-gated identity.

**What happened.** Honest `hasRole` only for alice: attacker `setAgentURI` reverts `NotController(attacker, agentId)`. A contract with `grantMe()` or a fallback returning `bytes32(1)` will then report the attacker as admin, because `_hasDefaultAdminRole` (`:645-648`) treats any nonzero 32-byte word as holding role 0. That is the bound contract's role model, already covered by `testDirtyBooleanReturnIsHandled`.

**Claude prior: plausible. DISAGREES** on seizing a *gated* identity. The adapter forwards `hasRole`; it does not invent membership.

---

## #8 ACCOUNT CREATE2 squat

**Verdict: DEFENDED.** `NotController` at `Adapter8004.sol:710-711` via `:776-780`.

**Test:** `test/security/GrokExploit_8_AccountCreate2Squat.t.sol`

**Success condition (finding):** before code exists at a predicted CREATE2 address, the attacker binds `ACCOUNT(predicted)` and later seizes a victim identity.

**What happened.** Victim `register(ACCOUNT, predicted, 0)` reverts `NotController(victim, type(uint256).max)`. Attacker gets the same revert. Skipping the code-length check (`:683-685`) does not skip the authority check. Only `msg.sender == boundAddress` (or a wallet-wide delegate of it) can bind. That requires deploying first. After CREATE2, the deployed contract owns *its own* new identity; `isController(victim)` is false. Different init code cannot occupy the victim's predicted address.

**Claude prior: plausible. DISAGREES.** There is no victim identity to squat. Codeless ACCOUNT binding is for the address acting as itself (EOA or constructor), not for a third party naming someone else's future address.

---

## #9 `_controlsAccount` ⊃ ACCOUNT binding control

**Verdict: DEFENDED-BY-DESIGN.** Two predicates, two surfaces. Identity writes still `NotController`.

**Test:** `test/security/GrokExploit_9_ControlsAccountSuperset.t.sol`

**Success condition (finding):** the vault `owner()` rewrites identity state (`setAgentURI`) while `isController` is false.

**What happened.** Vault is `ACCOUNT` and the sole identity controller. `owner()` is not `isController`. `setAgentURI` from `owner()` reverts `NotController(owner, agentId)` (`:696-697`). `setWalletUBIDFor` from `owner()` succeeds, because `_controlsAccount` (`:630-638`) includes `owner()`. A stranger still reverts `NotAccountController`. The reverse pointer is an account assertion, which is what the `For` surface is for.

**Claude prior: plausible. DISAGREES** that this is control of the identity. The identity is untouched.

---

## #10 Enum-extension fallthrough to ERC-6909

**Verdict: DEFENDED** on v0.0.17. ABI enum range check rejects `standard = 8` before `_hasBindingControl`.

**Test:** `test/security/GrokExploit_10_EnumFallthrough.t.sol`

**Success condition (finding):** `standard = 8` is accepted and gated by `IERC6909.balanceOf`.

**What happened.** Raw `register(uint8=8, …)` and `counterfactualSetAgentURI(uint8=8, …)` both revert with empty return data (ABI decoder). The real `ERC6909` branch still registers. The source fallthrough at `:826` is a *future* upgrade footgun if a ninth enum member is appended without a new `if`; it is not reachable today because `IERC8217.Standard` max is 7 (`CONTRACT_ADMIN`).

**Claude prior: plausible. DISAGREES** that it is exploitable on this version. Agree it is a review note for the next append.

---

## #11 Unclaimable phantom UBIDs

**Verdict: DEFENDED-BY-DESIGN.** Attest is unscoped; the phantom cannot occupy the canonical identity.

**Test:** `test/security/GrokExploit_11_PhantomUbid.t.sol`

**Success condition (finding):** attestations against `hashBinding(ACCOUNT, victim, 7)` attach to the victim's real identity, or the victim cannot claim `ACCOUNT(victim, 0)`.

**What happened.** `hashBinding` (`:312-313`) does no validation, so the phantom hash exists. It is **not** `hashBinding(ACCOUNT, victim, 0)`. `attest` on the phantom succeeds (`:598-605`, any nonzero `ubid`). `counterfactualRegister`, `register`, and `setWalletUBID` for `(ACCOUNT, victim, 7)` all revert `NonZeroTokenIdForAccount` (`:736-738`). Victim `register(ACCOUNT, victim, 0)` succeeds and `bindingHashOf` is the canonical hash, not the phantom.

**Claude prior: plausible. DISAGREES.** This is log spam of an unreachable key, not a forged or captured identity. The hole `testWalletUBIDRejectsCoordinatesNoClaimCanMatch` closed on the reverse-pointer path stays closed.

---

## #12 UBID → agentId one-to-many

**Verdict: DEFENDED.** Non-holders cannot mint a row. First binding is not rebound.

**Test:** `test/security/GrokExploit_12_UbidOneToMany.t.sol`

**Success condition (finding):** a non-holder forges a second registry row for someone else's identity, or the first `agentId` is silently rebound.

**What happened.** Attacker without balance: `register` reverts `NotController(attacker, type(uint256).max)` (`:710-711`). After they hold 1 wei they can register *their own* row (the 1155 multi-holder model). Distinct `agentId`s, equal `bindingHashOf`, first row URI and binding unchanged. Stranger cannot duplicate an ERC-721 row (`NotController`). There is no on-chain UBID→agentId resolver to hijack.

**Claude prior: plausible. DISAGREES.** Duplicate registration by current controllers is intended and already tested. An attacker who is not a controller cannot land a row.

---

## #14 Pre-claim key-space poisoning

**Verdict: DEFENDED** for a stranger. Collection planting is **DEFENDED-BY-DESIGN** (accepted ownerless window).

**Test:** `test/security/GrokExploit_14_PreclaimKeyPoison.t.sol`

**Success condition (finding):** a stranger writes counterfactual metadata on an unminted id.

**What happened.** Stranger `counterfactualSetMetadata` on an unminted 721 reverts `nonexistent token` — unwrapped `ownerOf` at `:808`, the accepted probe revert. They never emit. The collection can plant key `x` via the ownerless window (`:727-729`), which is the accepted #1 class. After mint the victim overwrites `x`; the stranger then reverts `NotController`.

**Claude prior: plausible. DISAGREES** that a stranger can poison. Collection-side planting is the bound collection using a documented window.

---

## #17 Front-run revocation poisoning

**Verdict: DEFENDED** by the published projection rule (revoker == attester).

**Test:** `test/security/GrokExploit_17_FrontrunRevocation.t.sol`

**Success condition (finding):** a stranger's earlier `revoke` of a predicted `attestationId` makes the later victim statement not live.

**What happened.** The identifier is fully determined (`:610-614`). Attacker `revoke(predicted)` then victim `confirmAdditionalAccount` in the same block. Both logs exist. Under the rule already pinned by `testNonAttesterRevocationIsIgnored`, the statement is still live because the revoker is not the attester. `_revoke` (`:621-625`) checks nothing by design; interpretation is off-chain.

**Claude prior: plausible. DISAGREES.** A correct projection does not suppress the statement. A `has-this-id-ever-been-revoked` indexer is wrong relative to the spec, not relative to a missing require.

---

## #18 Registry key-normalization mismatch

**Verdict: DEFENDED.** Exact keccak reservation. Production ERC-8004 registry also keys by the raw string.

**Test:** `test/security/GrokExploit_18_KeyNormalization.t.sol`

**Success condition (finding):** a case/whitespace/NUL variant of `agent-binding` overwrites the canonical 20-byte adapter address.

**What happened.** Exact `"agent-binding"` reverts `ReservedMetadataKey` (`:210-211`, `:900-908`). `"Agent-Binding"`, `"agent-binding "`, and `"agent-binding\0"` write *different* slots. `getMetadata(agentId, "agent-binding")` remains `abi.encodePacked(adapter)`. The bundled `IdentityRegistryUpgradeable.setMetadata` stores `$._metadata[agentId][metadataKey]` with no case-fold, trim, or NFC.

**Claude prior: plausible. DISAGREES** that this forges the reserved record on the actual registry. A future normalizing registry would be a registry-side break of an exact-key assumption, not an adapter bug in v0.0.17.

---

## #19 Blind `setAgentWallet` signature forwarding

**Verdict: DEFENDED.** Registry EIP-712 binds `agentId`. Replay reverts `invalid wallet sig`.

**Test:** `test/security/GrokExploit_19_WalletSigReplay.t.sol`

**Success condition (finding):** a wallet-consent signature for agent A assigns the wallet on agent B.

**What happened.** Adapter `_requireController` then forwards `(newWallet, deadline, signature)` verbatim (`:244-248`). The registry (mock and `lib/erc-8004-contracts` `:149`) hashes `AgentWalletSet(agentId, newWallet, owner, deadline)`. Replay of A's signature on B reverts `invalid wallet sig`. B's wallet stays `address(0)`. Attacker calling `setAgentWallet` on A reverts `NotController(attacker, agentA)`.

**Claude prior: plausible. DISAGREES.** The adapter inherits the registry's replay properties, and those properties already bind `agentId`. A registry that omitted `agentId` from the struct would be a registry bug; this one does not.

---

## Disagreements with the Claude priors

All twelve mechanisms were worth *trying*. None survived as a contract finding.

| # | Claude prior | Grok verdict | Disagree? |
|---:|---|---|---|
| 2 | plausible, break boolean oracles | DEFENDED-BY-DESIGN (revert, no wrong bool) | **Yes.** Revert is accepted. |
| 4 | plausible, every caller controls | DEFENDED-BY-DESIGN (hostile `owner()`) | **Yes.** Trust `owner()`. |
| 5 | plausible, seize admin-gated identity | DEFENDED on honest AccessControl; permissive contracts are the token | **Yes** on "gated". |
| 8 | plausible, CREATE2 squat | DEFENDED (`NotController` until the address itself calls) | **Yes.** No victim identity exists to steal. |
| 9 | plausible, rewrite without control | DEFENDED-BY-DESIGN (For-surface ≠ identity control) | **Yes.** `setAgentURI` still reverts. |
| 10 | plausible, silent 6909 gate for standard 8 | DEFENDED (ABI rejects 8) | **Yes** as a current exploit. Latent upgrade note only. |
| 11 | plausible, unclaimable victim history | DEFENDED-BY-DESIGN (different UBID; canonical still claimable) | **Yes.** |
| 12 | plausible, resolver lands on attacker row | DEFENDED (non-holder `NotController`; no on-chain resolver) | **Yes.** |
| 14 | plausible, undeletable poison on future identity | DEFENDED for strangers; collection window is #1-class | **Yes.** |
| 17 | plausible, suppress pending attestation | DEFENDED (non-attester revoke ignored) | **Yes.** |
| 18 | plausible, forge `agent-binding` | DEFENDED (exact key; registry does not normalize) | **Yes.** |
| 19 | plausible, replay wallet consent | DEFENDED (`agentId` in EIP-712; `invalid wallet sig`) | **Yes.** |

**Zero findings filed.** The attestation/UBID/metadata cluster (#11, #12, #14, #17, #18, #19) is where a real forgery would have lived; each one stopped at a concrete revert or at a non-colliding hash.

---

## Test inventory (this pass)

| File | Tests |
|---|---|
| `GrokExploit_2_IsControllerNotTotal.t.sol` | 3 |
| `GrokExploit_4_TxOriginOwner.t.sol` | 2 |
| `GrokExploit_5_PermissiveAdminRole.t.sol` | 3 |
| `GrokExploit_8_AccountCreate2Squat.t.sol` | 1 |
| `GrokExploit_9_ControlsAccountSuperset.t.sol` | 1 |
| `GrokExploit_10_EnumFallthrough.t.sol` | 1 |
| `GrokExploit_11_PhantomUbid.t.sol` | 1 |
| `GrokExploit_12_UbidOneToMany.t.sol` | 2 |
| `GrokExploit_14_PreclaimKeyPoison.t.sol` | 2 |
| `GrokExploit_17_FrontrunRevocation.t.sol` | 1 |
| `GrokExploit_18_KeyNormalization.t.sol` | 1 |
| `GrokExploit_19_WalletSigReplay.t.sol` | 1 |
| **New this pass** | **19** |
| Prior Grok likely-pass tests | 9 |
| Pre-existing | 401 |
| Full suite | **429 passing, 0 failed** |
