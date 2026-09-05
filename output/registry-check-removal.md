# RegistryMismatch upgrade-check removal

Task: `finish-registry-check-removal` (`e69dd73b-a7a0-41ed-bef7-a9b9dec174c9`)

## Decision implemented

`RegistryMismatch` was not a security control. It could govern only the next upgrade: an authorized owner could first install an implementation without the check and then install an implementation using another registry. A hostile implementation could also return the value expected by the check while using other state or behavior, exactly as `RegistrySpoofImpl` demonstrates. The effective security boundary for upgrades is `onlyOwner`; the removed equality check only caught an honest owner's mistake. The codebase deliberately does not spend contract code guarding that trusted party from its own reviewed upgrade choice.

## Security scenario change

Changed only `test/security/GrokExploit_20_RegistryMismatchSpoof.t.sol` for the implementation work in this task. The file and `RegistrySpoofImpl` remain intact as evidence.

- Renamed and reframed the honest different-registry scenario to `test_trustBoundary_ownerCanRepointToAnHonestDifferentRegistry`. An authorized owner upgrades to the honest implementation, and the test positively asserts that the proxy now reports the owner-approved different registry. The old `RegistryMismatch` revert expectation was removed because that error and behavior no longer exist.
- Left `test_defense_nonOwnerCannotInstallASpoofImpl` behavior and assertions unchanged. A non-owner still cannot install the spoof implementation; `onlyOwner` is the real defense.
- Renamed and reframed the owner-approved spoof scenario to `test_evidence_removedCheckCouldBeSpoofedByOwnerApprovedCode`. It still proves that the implementation can expose the expected `identityRegistry()` value while carrying a second harmful registry and becoming live after owner approval. This documents why equality against an implementation-supplied getter never established a security invariant.

No assertion was weakened merely to make the suite green. The one changed behavioral assertion now encodes the explicitly selected trust model: an authorized owner can repoint the registry on chain. The non-owner rejection remains unchanged, and the spoof proof retains both of its substantive postconditions.

## G2-01 invariant comment assessment

The `_authorizeUpgrade` comment at `src/Adapter8004.sol:663-674` is clear enough to stop a careful reader contemplating a registry change. It states all of the essential coupling explicitly:

- every future implementation must use the same registry;
- this is deliberately not enforced on chain;
- `_bindings[agentId]` is written unconditionally with no unused-ID check;
- safety depends on the registry ID sequence never restarting or reissuing an already-bound ID;
- a registry change lets ordinary registrations overwrite earlier bindings;
- this is audit finding G2-01, binding capture, with two working proofs of concept;
- a fresh registry is sufficient and no hostile registry is required; and
- any genuine future registry change must first guard the binding write.

That is stronger than a generic warning: it identifies the exact write, failure mechanism, audit finding, evidence, and prerequisite remediation.

## Stale statements found (reported, not changed)

### `CHANGELOG.md`

`CHANGELOG.md:622-638` correctly explains G2-01, the unconditional binding overwrite, and the registry-sequence dependency. However, `CHANGELOG.md:640-649` immediately contradicts the current contract by saying `_authorizeUpgrade` enforces registry equality and introduces `RegistryMismatch`. That paragraph is now false and should be revised before release. It was inspected but not changed because this task's implementation scope was the one security-test file and the manager requested reporting rather than necessarily fixing these texts.

### `script/DeployAdapterImplementation.s.sol`

Two signer/deployment statements are stale:

- Lines 91-96 say `_authorizeUpgrade` performs the equality check on chain and that every hop after the bootstrap is contract-guarded.
- The Safe transaction description at line 220 says `_authorizeUpgrade` rejects a different registry with `RegistryMismatch`, so later upgrades cannot repoint the proxy.

The second statement is high impact because it is presented directly to Safe signers deciding whether to approve an upgrade. The deployment script's preflight equality requirement at lines 97-102 still performs an off-chain/operator check for this deployment, but it must not be described as an enduring on-chain guarantee. No script text was changed in this task.

## Verification

- `forge build && forge test`: exit 0. The verbose run completed 84 test suites with 473 passed, 0 failed, and 0 skipped.
- Repeated after the final naming/comment cleanup with `forge build -q && forge test -q`: exit 0.
- The scenario suite specifically passed all three tests: authorized honest registry repoint, non-owner rejection, and owner-approved spoof evidence.

Compiler/linter warnings shown by the verbose build pre-existed this focused test edit and did not fail the gate.

## Git/worktree scope

The worktree was already dirty and contained many modified and untracked user/agent files. In particular, `src/Adapter8004.sol` and `test/Adapter8004.t.sol` already held the manager-described removal and opposite-behavior test before this task began; they were reviewed but not edited here. `test/security/GrokExploit_20_RegistryMismatchSpoof.t.sol` was already untracked, so ordinary `git diff` does not display its changes against the index.

Files written by this task:

- `test/security/GrokExploit_20_RegistryMismatchSpoof.t.sol` — focused scenario framing and honest behavior assertions.
- `output/registry-check-removal.md` — this human-auditable report.

No changes were made to `CHANGELOG.md`, `script/DeployAdapterImplementation.s.sol`, or unrelated dirty-worktree files.
