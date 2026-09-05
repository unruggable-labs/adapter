# Adapter8004 v0.0.17 — Grok execution of the two long-shot scenarios

Closes the 20/20 list. Independent run against `/Users/nxt3d/projects/adapter-0.0.17`. No `src/` edits. No existing-test edits.

`forge test`: **433 passed, 0 failed**. Prior **429** still green. **4** new tests this pass.

Standing rules: a mere revert is accepted; hostile bound tokens are DEFENDED-BY-DESIGN; a finding is a wrong bool, state corruption, or a forgeable reserved record.

---

## #13 Same-chainid fork replay

**Verdict: DEFENDED-BY-DESIGN.** The identifier scheme binds to this chain via `block.chainid`. A fork that keeps that chainid is the same chain identity, not a cross-chain replay.

**Test:** `test/security/GrokExploit_13_SameChainidForkReplay.t.sol`
`test_defense_identifiersBindToChainIdSoASameIdForkIsTheSameChain`

**Success condition (finding):** `hashBinding` and `attestationId` are identical across two different `block.chainid` values.

**What happened.** On chainid `N`, UBID `U` and attestation id `A`. On chainid `N+1`, both differ. Restoring `N` restores `U` and `A` exactly. Nothing in the adapter omits chainid or lets a distinct chainid collide.

**Mechanism.** `_interoperableAddress` (`Adapter8004.sol:929-930`) encodes `block.chainid`. `_bindingHashFrom` (`:961-968`) hashes that envelope with `(standard, boundAddress, tokenId)`. `_attest` (`:610-614`) hashes the same envelope with `(attester, ubid, type, block.number, variant, data)`. A second chain with a *different* chainid cannot replay those identifiers. A second chain with the *same* chainid and the same adapter address produces the same identifiers because the adapter's domain *is* `(chainid, adapter)` — that is ERC-7930, not a missing salt. Consumers who need to tell two forks with one chainid apart need a fork-id the EVM does not put in `block.chainid`.

**Claude prior: long shot. DISAGREES that this is an adapter replay bug.** Agree the same-chainid case is untested in the old suite; the PoC shows it is identity, not leakage. The complement (`hashBinding` moves with chainid) was already in `testCounterfactualRegistrationHashChangesWithChainId`.

---

## #20 `RegistryMismatch` spoofable

**Verdict: DEFENDED** against a differently-baked honest implementation (`RegistryMismatch` at `:670-671`). **DEFENDED-BY-DESIGN** against an owner-approved impl whose `identityRegistry()` getter matches. Not a privilege escalation.

**Test:** `test/security/GrokExploit_20_RegistryMismatchSpoof.t.sol`

**Success condition (finding):** an implementation baked with a different registry passes `_authorizeUpgrade`, or a non-owner installs a spoof.

**What happened.**

1. `HonestNextImpl` constructed with a second registry: owner `upgradeToAndCall` reverts `RegistryMismatch`. Proxy `identityRegistry()` unchanged.
2. Non-owner `upgradeToAndCall` of a spoof that *would* pass the getter: reverts (owner gate, `:667` `onlyOwner`).
3. Owner-approved `RegistrySpoofImpl` that returns the expected registry from `identityRegistry()` and carries a second registry in another immutable, with a valid UUPS `proxiableUUID`: the upgrade **lands**. Getter still names the original registry; `captured()` on the proxy is the harmful address.

**Mechanism.** `_authorizeUpgrade` (`:667-672`) is `onlyOwner` and compares `Adapter8004(newImplementation).identityRegistry()` to the outgoing immutable. That is a constructor-arg typo check, not a bytecode verifier. UUPS then requires `proxiableUUID() == IMPLEMENTATION_SLOT`. A hostile impl the owner signs can return the expected registry from that one getter and do anything else — the same precondition as any UUPS upgrade.

**Claude prior: long shot. DISAGREES on two counts.**

- **"No negative test anywhere" is false.** `testUpgradeRejectsAnImplementationBakedWithADifferentRegistry` in `test/Adapter8004.t.sol:961-970` already expects `RegistryMismatch`. This PoC re-proves it.
- **Spoof-as-finding is the UUPS owner model, not a bypass.** The lying getter passing under `onlyOwner` is expected. The guard does what it says: refuse a *mismatched getter*. It does not, and cannot, refuse owner-chosen bytecode. Signers are protected against deploying the next impl with the wrong constructor arg, not against approving a malicious impl.

---

## Disagreements with the Claude priors

| # | Claude prior | Grok verdict | Disagree? |
|---:|---|---|---|
| 13 | long shot, replay history onto a forked chain | DEFENDED-BY-DESIGN (identifiers bind to chainid) | **Yes** as a contract bug. Same chainid is the same domain. |
| 20 | long shot, spoofable guard, no negative test | DEFENDED (`RegistryMismatch` + `onlyOwner`); lying getter is owner-trust | **Yes** on "no negative test" (it exists) and on treating owner-approved spoof as a finding. |

**Zero findings filed.** 20/20 executed. The only scenario still worth a ticket from the whole list remains **#1** from the likely pass (hostile-collection ownerless window), which was later **rejected** as an accepted single-owner binding rule.

---

## Test inventory (this pass)

| File | Tests |
|---|---|
| `GrokExploit_13_SameChainidForkReplay.t.sol` | 1 |
| `GrokExploit_20_RegistryMismatchSpoof.t.sol` | 3 |
| **New this pass** | **4** |
| Prior Grok tests (likely 9 + plausible 19) | 28 |
| Pre-existing | 401 |
| Full suite | **433 passing, 0 failed** |
