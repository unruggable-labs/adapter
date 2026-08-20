# Changelog

All notable changes to the Adapter8004 contract are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the contract aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
via the `@custom:version` tag in [`src/Adapter8004.sol`](./src/Adapter8004.sol).

Formal `@custom:version` numbering began at `0.0.6`. Earlier upgrades were
tracked by dated deployment reports in [`deployments/`](./deployments) and are
listed under "Earlier history" below by deployment date.

The adapter is a Safe-owned UUPS proxy. A source version is not live until its
implementation is deployed and the proxy is upgraded via the multisig. Confirm
the live implementation on a block explorer before relying on a version.

**Currently live on-chain (verified from EIP-1967 slots on 2026-07-29; per-chain — they differ):**

- **Sepolia** (`0x7621…`): the **delegate.xyz v2** implementation
  (`0x31a68E5b…`). Proxy was upgraded, so delegate.xyz support is live here.
- **Base** (`0x270d…`): the **2026-05-15 counterfactual** implementation
  (`0x0f81bd4E…`). delegate.xyz is NOT live (its impl was deployed but the proxy
  was not upgraded).
- **Mainnet** (`0xde15…`): the counterfactual implementation
  (`0xa6D23f27…`). delegate.xyz is NOT live (its impl was never deployed here).

Numbered source versions `0.0.6`-`0.0.17` are not live on any chain. In
particular, the primary-agent layouts in `0.0.9`-`0.0.13` are not production
upgrade baselines. Re-verify the EIP-1967 implementation slot before relying
on this summary; see the
[last-deployed baseline audit](./deployments/upgrade-baseline-from-last-deployed.md).

Re-verified on 2026-08-19 for the `0.0.17` identifier change, reading the
EIP-1967 slot on each chain and calling through each proxy:

- the three implementation addresses above are still the active ones;
- all three proxies still compute the **pre-ERC-7930** registration hash
  `keccak256(abi.encode(block.chainid, address(this), boundAddress, tokenId))`,
  reproduced exactly off chain for each chain, so every live identifier is on the
  scheme `0.0.14` already supersedes;
- `interoperableAddress(address)` reverts on the Mainnet and Base proxies, so no
  live implementation has the ERC-7930 surface at all;
- `primaryCounterfactualAgentOf(address)` reverts on all three, so no live
  implementation exposes the counterfactual-primary surface and **slot 3, the
  only slot that could hold a counterfactual identifier, is unreachable and has
  never been written on any deployment.** The two deployed source baselines
  (`a20035c`, `4647ddd`) declare regular slots 0 and 1 only, which is the same
  conclusion from the other direction.

Together these mean the `0.0.17` identifier change costs nothing on chain: it
rides the cutover `0.0.14` already forces, and re-keys no stored value.

## [0.0.17] - Unreleased

**This is the version the artifact carries.** `0.0.14` through `0.0.17` are one
implementation, not four releases. None has been deployed. They are separate
sections because they group unrelated work, not because they ship separately:
the sections record what changed, and `@custom:version` in
[`src/Adapter8004.sol`](./src/Adapter8004.sol) records what the single resulting
implementation is called. Read all four together when reviewing an upgrade.

Adds no storage slot and keeps the `0.0.14` layout, so it upgrades from the same
deployed baselines with empty `upgradeToAndCall` data. That holds for the
attestation surface below as much as for the identifier change: the whole
subsystem is emit-only, so the layout still ends at slot 4.

### Added

- **An emit-only attestation surface for counterfactual identities.** Three
  external functions, two events, two errors, five published type constants:

  ```
  attest(bytes32 attestationType, bytes32 cfid, bytes32 variant, bytes data)
  confirmAdditionalAccount(bytes32 cfid)
  revoke(bytes32 attestationId)
  ```

  An attestation is a public statement about a counterfactual registration hash.
  Its meaning rests entirely on who made it, and who made it is always the caller.
  The contract records the statement, derives its identifier, and judges nothing
  else: not the target's existence, not the payload's shape, not the attester's
  independence from the subject. All of that is the reader's, and the projection
  rules, payload encodings, and type registry live in
  [`docs/specs/attestation-type-registry-v1.md`](./docs/specs/attestation-type-registry-v1.md).

  **Why it exists.** ERC-8004's reputation registry only accepts feedback on
  registered agents, so an agent's entire pre-registration history is
  unrecordable, and ERC-8048's additional-account list is one-directional, so no
  account can confirm or refuse a listing made about it. This closes both: a
  statement can attach to an identity that has not registered, and
  `confirmAdditionalAccount` is the reciprocal half of the ERC-8048 `account`
  key.

- **The identifier**, emitted so integrators never recompute it:

  ```
  keccak256(abi.encode(
      adapterInteroperableAddress, attester, cfid, attestationType,
      block.number, variant, data
  ))
  ```

  `block.number` bounds a revocation's blast radius to one block, so a monitor
  emitting byte-identical pings over time does not collapse its whole history
  into one identifier that a single revocation erases. `variant` is the caller's
  opt-in within-block counterpart. There is deliberately **no domain constant**:
  nothing here is signed, and the interoperable address already binds the
  preimage to this adapter on this chain, exactly as `registrationHash` binds.
  The two schemes cannot collide, because for one adapter the counterfactual
  preimage is a fixed 224 bytes and this one is at least 320.

- **The caller is always the attester.** There is no acting-for path and no
  submitter field. A controller participates by causing the account itself to
  make the call, so the account is still `msg.sender`, and nothing can
  manufacture an account's consent from outside it. The stated cost is that an
  account which cannot make outbound calls — a minimal vault, a payment splitter
  with no executor — cannot attest. Ordinary wallets, multisigs, smart wallets
  with executors, timelocks and EIP-7702-delegated accounts all can.

- **The type is a closed `AttestationType` enum**, declared on
  `IERC8004AdapterAttestation`: `UNSPECIFIED`, `CONFIRM_ACCOUNT`, `STAR`,
  `RATING`, `REVIEW`, `INTERACTION`. The set is fixed by the deployed
  implementation, so admitting a sixth type is an upgrade.

  An earlier build of this branch used open hash-named `bytes32` constants that
  any third party could extend under their own namespace. The enum was chosen
  because a type is what an enum is for, because `TokenStandard` in this same
  contract is already an enum, and because the contract is upgradeable, so the
  cost of admitting a type is an upgrade the owner can already make. The open
  namespace is the capability given up, knowingly.

  `UNSPECIFIED` occupies zero because Solidity enums start there. Without it the
  first real type would be the value a default-initialized variable carries,
  which is exactly what `AttestationTypeZero` exists to reject; with it the guard
  keeps working unchanged in meaning.

  **The numbering is identity-critical**, in the same way `TokenStandard`'s
  became: the `uint8` sits in the `attestationId` preimage, so renumbering a
  member re-keys every attestation ever emitted under it and every revocation
  naming one. Nothing on chain records the old value. Append only, never reorder,
  never remove. The rule is recorded on the enum itself.

  One capability gained: the **ABI decoder rejects an out-of-range value before
  any contract code runs**, so a garbage type is refused for free rather than by
  a check, and can never reach the log. No guard implements that.

- **Three new entry points, not eight.** The five `bytes32 public constant`
  declarations and their five generated readers are gone with the enum. An
  earlier plan said six constants and nine entry points; that count also predated
  the domain constant being dropped from the identifier scheme.

- **Every attestation identifier moved**, which is why this was not a rename.
  `abi.encode` of a `bytes32` is the raw 32 bytes; `abi.encode` of an enum is its
  `uint8` right-aligned in a word. The preimage therefore changed, and all five
  published vectors in
  [`docs/fixtures/adapter-attestation-ids.md`](./docs/fixtures/adapter-attestation-ids.md)
  were recomputed from scratch, off chain, before the code changed. The
  superseded constants and identifiers are retained there for identification.
  `Attested`'s ABI signature moved from
  `Attested(address,bytes32,bytes32,bytes32,bytes32,bytes)` to
  `Attested(address,uint8,bytes32,bytes32,bytes32,bytes)`, so its `topic0`
  changed, and `attest`'s selector moved with its signature. Nothing was
  deployed under the old scheme, so no on-chain record is orphaned.

### Deliberately absent

- **No storage, anywhere.** The identifier is derived and never stored, the
  constants live in code, and no function writes a slot. This is asserted rather
  than asserted-in-a-comment: a test captures every `SSTORE` the three functions
  perform with `vm.record` and requires the count to be zero, and a second test
  reads slots 5 through 12 back as zero.

- **No reentrancy guard**, unlike the counterfactual emit-only surface, which
  carries `nonReentrant`. These functions make no external call of any kind, so
  the guard would spend roughly 2,900 gas per call to protect against nothing.
  **This is a decision, not an omission to be tidied up later as a consistency
  fix.** A test forces the guard slot to `ENTERED`, confirms a guarded
  counterfactual function reverts in that state, and requires all three
  attestation functions to go through; adding the modifier fails that test.

- **No target validation.** A nonzero `cfid` that matches no claim passes on
  purpose. Counterfactual registration writes no storage, so no set of "real"
  hashes exists to check against, and attesting ahead of an identity's first
  claim is the supported case rather than an edge one.

- **No check on `revoke`, the zero identifier included.** Revoking a statement
  never made is a recorded no-op for readers, so a sentinel there would guard
  against nothing, whereas an unset type or target would file a real statement in
  the wrong place. Those two are the only guards, and each has a test that fails
  if the check is deleted.

### Gas

Measured on this implementation, execution cost excluding the fixed 21,000 per
transaction, warm:

| Function | Measured | Earlier estimate |
| --- | ---: | --- |
| `attest`, small payload | 6,385 | 4,700–5,400 |
| `confirmAdditionalAccount` | 5,902 | 4,500–5,100 |
| `revoke` | 1,889 | 2,200–2,700 |

Payload bytes add roughly 9 gas each, the author's cost by design for `REVIEW`.

These numbers are what they are because of the ERC-7930 encoder rewrite recorded
under "Changed" below. Before it, `attest` measured 13,387 and
`confirmAdditionalAccount` 12,904 — about two and a half times their estimates —
and an earlier revision of this section attributed the gap to `_interoperableAddress`
building the envelope byte by byte, at roughly 8,000 gas a call. That diagnosis
was right and has now been acted on, so the numbers it described no longer hold
and the table above replaces them. `revoke` is unchanged at 1,889, because it
derives no identifier and so never touches the encoder.

The `AttestationType` enum, separately, did not make any of these cheaper. It made
them very slightly dearer than the `bytes32` constants did — `attest` by 109 gas,
`confirmAdditionalAccount` by 38, `revoke` by 44 — because the decoder's range
check is real work and because removing five public getters reshuffles the
selector dispatch the other functions walk through. The enum's saving is in code
size, not gas.

### Changed

- **The ERC-7930 encoder is now differentially tested against OpenZeppelin and
  against the spec.** `ReferenceErc7930` proves the word-aligned rewrite is
  faithful to the code it replaced, but it cannot prove that code ever read
  ERC-7930 correctly: a misreading present in both would agree with itself and
  every identity this contract issues would be wrong the same way.

  Added, all test-only: a differential fuzz against OpenZeppelin 5.6.1's
  `draft-InteroperableAddress` on both shapes with the reference length picked
  explicitly rather than sampled; the real chain ids and both fast-path handoffs
  held against it; a round trip through its `parseEvmV1`, which is what a third
  party integrating with these identifiers will actually run; and the three EVM
  reference examples from the ERC-7930 text pinned as exact bytes, asserted
  against both encoders so a mis-transcribed literal fails rather than agreeing.

  Everything agrees. The one candidate divergence, the trailing `AddressLength`
  byte on the address-free form, is settled by OpenZeppelin's own source, which
  appends `uint8(0)` exactly as this contract does, and by spec example 6.

  The library stays out of `src/`, so runtime size is unchanged, and it was
  already in the test build, so it costs nothing new.

- **`_erc7930AddressFor` is word-aligned.** The ERC-7930 envelope is now built
  with a single `MSTORE` for every case that fits in a 32-byte word, instead of up
  to twenty-six bounds-checked byte writes. The byte-at-a-time loop is kept as the
  fallback for chain ids too large to fit, so the encoder stays total.

  `length <= 32` is the exact condition for both shapes at once: with an address
  the envelope is `26 + L` bytes, so the fast path covers `L <= 6`, meaning chain
  ids below 2^48; without one it is `6 + L`, covering `L <= 26`. Every chain in
  existence is far inside both.

  **Every identity this contract derives comes through this helper** — every
  counterfactual `registrationHash`, every `attestationId`, and the EIP-712
  surface — and a one-byte divergence would silently re-key identities rather than
  revert. So byte-identity is the safety argument, not a nicety. The pre-rewrite
  encoder is kept verbatim as `ReferenceErc7930` in
  [`test/Adapter8004.erc7930.t.sol`](./test/Adapter8004.erc7930.t.sol) and the
  rewrite is fuzzed against it across both shapes and all 32 reference lengths,
  with the fast-path/fallback handoff pinned explicitly from both sides and a
  memory-guard fuzz proving the store stays inside its allocation. The published
  vectors in both fixture documents still pass untouched, which is the same
  property checked from the outside. Do not delete that reference: a test that
  compares the new encoder to itself proves nothing.

  Measured saving, on the same basis before and after:

  | Function | Before | After | Δ |
  | --- | ---: | ---: | ---: |
  | `attest`, small payload | 13,387 | 6,385 | −7,002 |
  | `confirmAdditionalAccount` | 12,904 | 5,902 | −7,002 |
  | `registrationHash` | 9,647 | 2,645 | −7,002 |
  | `revoke` | 1,889 | 1,889 | 0 |

  Exactly one derivation's worth in each case. The alternatives were priced and
  rejected: caching the chain-dependent prefix in an `immutable` recovers only
  about 3,300 of that, because the expensive half is the twenty address bytes and
  `address(this)` in a constructor is the implementation rather than the proxy; a
  storage cache is the only mechanism that can capture the proxy address, and it
  wins about 700 gas warm while losing about 1,400 on the cold first touch that
  most transactions actually pay, in exchange for a storage slot. This option
  changes no deployment property at all.

- **The counterfactual identity gains the token standard.** The
  `registrationHash` preimage becomes five components:

  ```
  keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, extraData))
  ```

  `standard` is the `TokenStandard` enum as its `uint8`, sitting between the
  adapter's ERC-7930 Interoperable Address and `boundAddress`. `extraData` is the
  existing reserved discriminator, still `bytes32(0)` everywhere. Always
  `abi.encode`, never packed.

  **Why.** Without the standard, token 5 on one contract collapsed to a single
  coordinate whether it was claimed as `ERC721`, `ACCOUNT` or `CONTRACT_OWNABLE`.
  The interface documented that aliasing as an accepted property, on the reasoning
  that the three claims were deliberately one identity resolved by last-event-wins.
  With attestations about to accumulate against these identifiers, aliasing stops
  being a documented quirk and becomes a way for one claimant's reputation to land
  on another claimant's identity. Including the standard dissolves it: two
  standards claiming one `(boundAddress, tokenId)` are now two identities with two
  separate histories, and last-event-wins resolves within one standard only.

  What the standard in the identity records is that the claimer passed *that
  standard's* authority probe at claim time. It is not an assertion that the bound
  contract conforms to the ERC; the adapter probes authority and never calls
  `supportsInterface`.

  **Cost on chain: none.** Every live proxy still runs the pre-ERC-7930 preimage
  `keccak256(abi.encode(block.chainid, address(this), boundAddress, tokenId))`,
  verified directly against Ethereum, Base and Sepolia on 2026-08-19. The
  ERC-7930 rewrite at `0.0.14` already forces a hard re-index, and no proxy ever
  ran the standard-less ERC-7930 preimage, so this rides that cutover rather than
  adding one.

- **`TokenStandard` numbering is now identity-critical.** The enum's `uint8` is in
  the preimage, so renumbering a member re-keys every counterfactual identity
  claimed under it, along with every attestation and reverse pointer naming one.
  Before this version the numbering was event-critical, which tolerated
  renumbering with a re-index. It no longer does. **Append only: never renumber,
  never reorder, never remove a member.** The constraint is recorded on the enum
  in [`IERCAgentBindings.sol`](./src/interfaces/IERCAgentBindings.sol).

- **`registrationHash(address,uint256)` is removed and replaced by
  `registrationHash(TokenStandard,address,uint256)`.** The old selector is gone
  rather than kept as an overload, deliberately: a stale caller reverts cleanly
  instead of silently computing a hash that no longer identifies anything.

- **`setPrimaryCounterfactualAgent` and `setPrimaryCounterfactualAgentFor` each
  gain a `TokenStandard` parameter**, immediately before `boundAddress`. Both old
  selectors are gone, for the same reason. `clearPrimaryCounterfactualAgent[For]`
  and `primaryCounterfactualAgentOf` are unchanged.

- **The five counterfactual update events and `PrimaryCounterfactualAgentSet` gain
  a non-indexed `standard`**, directly after `extraData`:
  `CounterfactualAgentURISet`, `CounterfactualMetadataSet`,
  `CounterfactualMetadataBatchSet`, `CounterfactualAgentWalletSet`,
  `CounterfactualAgentWalletUnset`. This makes a log line verifiable on its own: a
  reader recomputes the `registrationHash` the event names from the event's own
  fields, with no lookup of the claim that created the identity. Their `topic0`
  values move, so indexers resubscribe. `CounterfactualAgentRegistered` already
  carried the standard in that position and its signature is unchanged.

### Unchanged, deliberately

- **The `Binding` struct is untouched**, and `extraData` was considered as a
  fourth field and rejected as too disruptive to existing bindings.
- **Storage is untouched.** The layout still ends at slot 4. No slot is added,
  reserved or repurposed, and the upgrade still takes empty `upgradeToAndCall`
  data.
- **`bindingOf` keeps its signature and return encoding**, and `AgentBound` keeps
  its shape and `topic0`.
- **`register` gains no parameter.** It already takes the standard.

### Size

`forge build --sizes` on this implementation:

| Contract | Runtime (B) | Initcode (B) | Runtime margin (B) |
| --- | ---: | ---: | ---: |
| `Adapter8004` | 19,492 | 19,777 | 5,084 |

Against the 24,576-byte cap, built up from `0.0.16`:

| Step | Runtime (B) | Margin (B) |
| --- | ---: | ---: |
| `0.0.16` | 18,400 | 6,176 |
| + the standard in the counterfactual identifier | 18,660 | 5,916 |
| + the attestation surface | 19,707 | 4,869 |
| − the five type-constant readers, replaced by the enum | 19,365 | 5,211 |
| + the word-aligned ERC-7930 encoder | 19,492 | 5,084 |

The attestation surface cost 1,047 bytes, under the 1,500–2,200 it was estimated
at, and the enum handed 342 of them back by deleting five public getters. The
encoder rewrite cost 127. That was predicted to land neutral or smaller, on the
reasoning that replacing the byte loops in place would delete more than the fast
path adds; it did not, because the fallback keeps those loops and the fast path's
shift arithmetic is added on top. It came in well under the +267 upper bound the
investigation gave, but it is a cost, not a saving. A test fails the suite if the margin ever falls below 2,000 bytes; if it
does, the fix is the extraction the upgrade docs describe, not a lower floor.
Extraction would re-key every attestation identifier, because the identifier
binds the emitting address, so it is a one-way door.

## [0.0.16] - Unreleased

**`0.0.14`, `0.0.15` and `0.0.16` are one implementation, not three
releases.** None of the three has been deployed. They are separate sections
because they group unrelated work, not because they ship separately.

Adds no storage slot and keeps the `0.0.14` layout, so it upgrades from the same
deployed baselines with empty `upgradeToAndCall` data.

The version was bumped because the implementation changed materially after the
`0.0.15` text was written. Two of those changes are recorded under `0.0.14`
below, where they belong by subject rather than by date: the appended
`CONTRACT_ADMIN` standard, and the removal of contract-self authority from
`CONTRACT_OWNABLE` and `CONTRACT_ADMIN`. That second one is a **breaking
authority change**, and anyone who reviewed an earlier build of this branch has
seen neither. The changes with no other home are listed here.

### Changed

- `setMetadataBatch` now emits one `MetadataSet` per entry, so a batch write and
  the equivalent sequence of single writes produce identical logs. **The
  `MetadataBatchSet` event is removed**, which is breaking for any consumer
  subscribed to its `topic0`. That event carried only a count, so it told a consumer
  that something had changed without saying what; the per-entry `MetadataSet` events
  that replace it name each key. The counterfactual mirror
  `CounterfactualMetadataBatchSet` is unaffected and still exists.
- **`CONTRACT` (value `5`) is renamed `ACCOUNT` and now accepts any address, with or
  without runtime code.** The enum position is unchanged, so no stored binding and no
  indexed history moves, and because enum member names do not appear in event
  signatures this changes no `topic0`. The standard is excluded from the
  counterfactual preimage, so no `registrationHash` changes either.

  The motivation is a defect rather than new permissiveness. There was exactly one
  code test on the register path, and `ACCOUNT` authority is a bare
  `msg.sender == boundAddress`. Under EIP-7702 a delegated externally owned account
  carries a 23-byte designator, which cleared that test, and an ordinary transaction
  from the same key cleared the authority check. So the shipped rule was never
  "accounts are excluded", it was "accounts are excluded unless a 7702 delegation
  happens to be installed at the moment of the call", which is arbitrary, undocumented,
  and flips as wallets configure themselves. Verified against the code before the
  change and now pinned by a test. The relaxation removes an accidental and unstable
  exclusion and makes the rule sayable: `ACCOUNT` names an address, and how that
  address is implemented is not the adapter's concern.

  The code test survives for every other standard, which all call into the bound
  address and so genuinely need it. It is a precise early error rather than the only
  gate: each probe already fails closed against a code-less address. The zero address
  is now rejected explicitly under every standard, `ACCOUNT` included, because
  `_bindings` uses a zero `boundAddress` as its unbound sentinel. The
  registry-address rejection is unchanged for every standard.

  **The consequence to document for integrators:** an address bound as `ACCOUNT` can
  install a 7702 delegation afterwards, which permanently widens who can act for that
  identity, and a binding is immutable so it cannot be undone. This is the same
  accepted shape as a `CONTRACT_OWNABLE` contract renouncing ownership. Counterfactual
  claims are less exposed, being emit-only and last-event-wins.

  **A second consequence, which the plan did not anticipate:** dropping the code test also
  drops the incidental bar on constructor-time binding. A contract can now bind itself as
  `ACCOUNT` from its own constructor, because `msg.sender` during construction is already
  its final address. Verified against the built contract. This is coherent with the
  standard rather than a hole, since `ACCOUNT` authority never calls the bound address, but
  it is a behavior change for anyone who read the previous "constructor calls are rejected"
  rule as universal, and it remains rejected for every other standard.

  `ACCOUNT` is offered no delegate.xyz route, which was a documented decision with no test
  behind it until mutation testing found that widening it passed the whole suite.
  `testAccountGrantsNoDelegationRoute` now pins it across every delegation shape the
  adapter honors elsewhere, including a blanket wallet-level grant.

  `NonZeroTokenIdForContract` is renamed `NonZeroTokenIdForAccount`, which changes that
  error's selector. Free only because value `5` has never been deployed, confirmed by
  reading the EIP-1967 implementation slots on Mainnet, Base and Sepolia and probing
  each live implementation for the selector, which is absent from all three.
- **`rewriteBindingMetadata` is removed**, along with the
  `BindingMetadataRewritten` event and `script/MigrateBindingMetadata.s.sol`. It was
  an owner-only helper that rewrote a legacy `agent-binding` row into the ERC-8217
  20-byte format.

  It is obsolete on its own terms, verified against the source rather than assumed.
  Commit `a20035c`, the implementation live on Mainnet and Base, already writes
  `abi.encodePacked(address(this))` on the register path and already contains this
  helper. So it migrates away from a format the live contract does not produce, and
  the tool has been deployed and available to the Safe the entire time it could have
  been needed. `deployments/2026-04-30-erc8217-migration-plan.md` records the migration
  script as "presently a prepared no-op for all three production proxies", and
  `deployments/2026-04-30-erc8217-upgrade-report.md` as "Today, no such rewrite is
  required".

  The decisive argument is the asymmetry that decided `bindExisting`. Removal is
  reversible through a later upgrade. Keeping an owner privilege that is not needed is
  not free: it has to be justified to every reviewer, forever.

  **Unlike the other removals in this release, this one withdraws a live surface.**
  `rewriteBindingMetadata` shipped in the deployed implementation, so the following
  identifiers disappear from Mainnet and Base at the upgrade and are listed here for
  anyone holding them:

  - `rewriteBindingMetadata(uint256)` selector `0x1ea11df7`
  - `BindingMetadataRewritten(uint256,address)` topic0
    `0xd8258bc58ec87d943ef12a8fb055cdfe4ca6adb9557a64fd8a3a36d0f3dec638`

  **The on-chain check for surviving legacy rows was deliberately not performed.** No
  scan of Mainnet, Base or Sepolia was run to confirm that no `agent-binding` row is
  still in the old format. That is recorded here so the record is honest rather than
  implied. Residual risk is low and bounded: a stranded legacy row is a
  discoverability defect, because `agent-binding` is what tells a consumer which
  adapter manages an agent, and it never affects authority, because
  `_hasBindingControl` reads `_bindings` and never reads the metadata. If such rows
  turn up, the helper can be reintroduced in a later version.

  **The invariant this completes:** `onlyOwner` is now exactly `setIdentityRegistry`
  and `_authorizeUpgrade`, both contract-level administration. **No owner function
  reaches into an individual agent's state.** The adapter owner cannot rewrite a
  binding, rewrite an agent's metadata, move an agent, or act as a controller for one.
  Changing `identityRegistry` is contract-wide configuration that changes where every
  agent resolves, which is why it stays Safe-owned, but it writes to no agent. This
  could not be claimed before, because this helper wrote to one agent's registry row
  on the owner's authority alone.

  `UnknownAgent` is **not** removed: `bindingOf` and the controller check still throw
  it.

- **`bindExisting` is removed.** It pulled an already-minted ERC-8004 agent into
  adapter management against an external token. The asymmetry with `register` is the
  whole argument. `register` mints an agent that is born bound, so nothing pre-existed
  and nothing can be lost. `bindExisting` took an identity that already existed
  independently and irreversibly subordinated it: afterwards the adapter owns the agent
  NFT permanently, control follows the bound token so selling that token hands the buyer
  the agent, ERC-8004 clears the agent wallet on transfer, the reserved `agent-binding`
  metadata is overwritten, and the binding is immutable.

  There is no way back. The adapter has no unbind, revoke, withdraw, rescue or recover
  function, and after this change it contains **no ERC-721 transfer of any kind, in
  either direction**. A caller who did not fully understand the consequences had no
  remedy, and the consequences are not obvious from the call.

  Removing the function is reversible: a later UUPS upgrade can reintroduce it, with a
  clearer surface, if the need is real. The harm it enabled is not reversible. That
  asymmetry decided it.

  **The invariant this buys, which is stronger than anything the contract had before:
  every agent the adapter holds a binding for was minted by the adapter, in the same
  transaction that created that binding.** There is exactly one write to `_bindings`, it
  sits in `_register`, and it is preceded by the registry mint. No independently
  existing identity can come under adapter management by any path. Something can still
  be sent to the adapter address by an outside ERC-721 transfer, but that creates no
  binding and is not manageable through the adapter, so it is a stuck token rather than a
  subordinated identity.

  The earlier `0.0.16` work that dropped `bindExisting`'s redundant ownership and
  approval pre-checks, and with them the `NotAgentOwner` and `AgentTransferNotApproved`
  errors, is moot now that the function is gone. Those two errors remain absent.

  `AlreadyBound` is removed with it. Its only `revert` was inside `bindExisting`, and
  `register` mints a fresh id that cannot already carry a binding, so the error became
  unreachable rather than merely unused.
- **The `tokenContract` field, parameter and event/error argument is renamed
  `boundAddress`** throughout the contract and interfaces, including
  `Binding.boundAddress`. The field is polymorphic: for values `0`-`4` it holds a
  token contract and the coordinate is `(contract, tokenId)`, while `ACCOUNT`,
  `CONTRACT_OWNABLE` and `CONTRACT_ADMIN` put the account itself there, and under
  `ACCOUNT` that may be an externally owned account. `tokenContract` was therefore
  factually wrong for the standard this release created, and it also disagreed with
  `_requireValidBoundAddress`, so the contract was carrying two names for one thing.

  **No function selector and no event `topic0` moves.** Solidity builds both from
  parameter types, not names, so the rename is invisible in the ABI encoding.
  Verified by diffing `forge inspect` method and event tables before and after: both
  byte-identical. A consumer decoding by selector or subscribing by topic needs no
  change. A consumer reading the field *by name* from a generated ABI, a typechain
  binding or an indexer schema does, since `Binding.tokenContract` is now
  `Binding.boundAddress`.

  Two error names encoded the old noun for a field that may now be an EOA and are
  renamed with it. **Error selectors do change with the name**, and both are listed
  here for anyone decoding them: `InvalidTokenContract()` `0x29bdfb34` becomes
  `InvalidBoundAddress()` `0xc243f1fe`, and `InvalidTokenContractIsRegistry()`
  `0xad9f118b` becomes `BoundAddressIsRegistry()` `0x021cdfc0`.
  (`NonZeroTokenIdForContract` became `NonZeroTokenIdForAccount` earlier in this
  release, for the same reason.)

  Prose that genuinely means a token contract is unchanged. The ownerless-collection
  window is open only to an ERC-721/ERC-1155F/ERC-6909F token contract, and
  `CONTRACT_OWNABLE` and `CONTRACT_ADMIN` really do require contract code, so those
  sentences still say contract. Only the field was renamed, not the facts.

  Free only because nothing is deployed. After an upgrade the parameter name is fixed
  in every consumer's ABI artifact.
- **`registerAndSetPrimary` is removed.** It was a one-transaction convenience
  wrapper: `register` followed by recording the new agent as the caller's own
  primary. The premise is that the caller wants the agent as *their* primary, and
  the authority model has two paths where that does not hold. A delegate.xyz
  delegate may register on the token owner's behalf, and the wrapper then pointed
  the *delegate's* primary at an agent bound to somebody else's token. An
  ownerless collection registering its own id got its own primary pointed at one
  arbitrary token's agent rather than the future buyer's. Neither is what a caller
  would want, and neither is fixable inside a function whose whole shape is
  "primary goes to `msg.sender`". It also bought nothing beyond one transaction:
  there is no atomicity to protect, since nothing can take your primary-agent slot
  between two transactions. `register` and `setPrimaryAgent` remain available
  separately and compose into exactly the intended case. This is breaking for any
  caller holding its selector, which is free to do now and would not be after a
  deployment.
- Built with **solc 0.8.30** targeting the **prague** EVM, both pinned in
  `foundry.toml` rather than left to the toolchain default. The bytecode and
  therefore the implementation `EXTCODEHASH` differ from any earlier build even
  where the source is unchanged, so compare a deployed implementation against a
  build from this pin and not against an older artifact.

## [0.0.15] - Unreleased

Breaking source release. Not deployed. Adds no storage slot and keeps the
`0.0.14` layout, so it upgrades from the same deployed baselines with empty
`upgradeToAndCall` data. This is part of the release train described under
`0.0.16` above, which also carries the unreleased `0.0.14` contract-binding
work below; all three ship together in one implementation.

### Changed

- `bytes32 extraData` is folded into the counterfactual registration-hash
  preimage, which is now
  `keccak256(abi.encode(adapterInteroperableAddress, boundAddress, tokenId, extraData))`.
  This implementation reserves `extraData` at `bytes32(0)` and has no way to
  supply another value; a future implementation may return non-zero values to
  distinguish subjects that share a `(boundAddress, tokenId)`. This is a hard
  identity cutover: every counterfactual `registrationHash` changes, so
  identities emitted by earlier implementations do not match anything recomputed
  by this one. On-chain `Binding` rows and full ERC-8004 registrations are
  unaffected.
- `extraData` is emitted as the first non-indexed field on all six
  counterfactual events (`CounterfactualAgentRegistered`,
  `CounterfactualAgentURISet`, `CounterfactualMetadataSet`,
  `CounterfactualMetadataBatchSet`, `CounterfactualAgentWalletSet`,
  `CounterfactualAgentWalletUnset`) and on `PrimaryCounterfactualAgentSet`, so
  an indexer stores the field before any upgrade begins populating it. Adding a
  field changes each event signature and therefore its `topic0`.

### Removed

- The `uint8 version` payload field on the counterfactual events and the
  `counterfactualPayloadVersion()` getter. `topic0` already discriminates event
  schema on its own, so an in-payload version restated what the topic guarantees.

## [0.0.14] - Unreleased

Breaking source release. Not deployed. Upgrades directly from the active
May 15 counterfactual implementation on Mainnet/Base and the active
delegate.xyz implementation on Sepolia. Both deployed baselines have only
regular slots 0 and 1. Uses empty `upgradeToAndCall` data (not an initializer
or reinitializer payload).
The primary-agent designs in unreleased `0.0.9` through `0.0.13` are superseded.

### Added

- Account bindings. `ACCOUNT` is appended to `TokenStandard` as value `5`; values `0`-`4` are
  unchanged, so stored bindings and indexed history keep their meaning. Values `0`-`4` name a token
  within a contract; `ACCOUNT` names any address itself, token or not. An ERC-20 claiming
  its own identity is the motivating example and uses `ACCOUNT` like any other contract. There is
  no ERC-20-specific standard value. (ERC-20Agent is a separate metadata profile layered on top, not a
  binding standard.)
  - `tokenId` MUST be `0`: an account-level binding has exactly one canonical coordinate. Any other
    id reverts the new `NonZeroTokenIdForAccount(boundAddress, tokenId)` error rather than being
    coerced, enforced at both authority choke points, so it covers `register` and every
    unsigned counterfactual writer.
  - The controller is the bound `boundAddress` itself and nothing else. No holder, delegate,
    optional `owner()`, or adapter admin has authority. The adapter probes neither `ownerOf` nor
    either `balanceOf` shape; control is `msg.sender == boundAddress`, so a contract with no token
    interface at all binds exactly like one that has one.
  - Unlike the transient ERC-721/ERC-1155F/ERC-6909F direct-collection window, which closes on mint
    and can reopen on burn, an account-level binding has no token whose ownership could change hands,
    so its authority window never closes. `ACCOUNT` is deliberately excluded from the single-owner
    set: no ownerless probe, no delegate.xyz route.
  - The adapter's immediate EVM caller must be `boundAddress`. A router, forwarder, or multicall
    contract that calls the adapter itself fails, because the adapter sees that contract as
    `msg.sender`. An external owner or governance address may instead call an entry point on the
    bound contract, which then makes the outbound adapter call (the planned reference pattern). As
    shipped in this version a constructor call is rejected, because deployed runtime code is required;
    v0.0.16 removes that requirement for this standard, so a constructor call now succeeds.
    `delegatecall` into `Adapter8004` is unsupported and dangerous: it is a UUPS implementation with
    its own storage layout, not a library.
  - Permanent authority is worth nothing without a repeatable outbound path to the adapter. A
    contract that cannot call out cannot bind at all; one with a single post-deployment hook binds
    once and then freezes. Repeatable management needs a governance-gated, upgradeable, or
    pass-through outbound path.
  - Post-bind, the mutable registry fields are bound-contract-only and its latest write wins. The
    `Binding` stays immutable with deliberately no revoke or unbind API. Register a fresh ERC-8004
    identity instead. Counterfactual claims likewise cannot be withdrawn. Later events from the
    contract supersede earlier ones by last-event-wins, and wallet unset is field-level.
- Ownable contract bindings. `CONTRACT_OWNABLE` is appended to `TokenStandard` as value `6`; values
  `0`-`5` are unchanged, so stored bindings and indexed history keep their meaning.
  - Authority is the current address returned by the bound contract's `owner()`, and delegate.xyz
    delegates of that owner. The bound contract itself has no authority under this standard.
    Self-authority is excluded deliberately: any contract with a generic call mechanism, an
    upgradeable implementation, or an inducible callback could otherwise seize its own identity
    without the owner acting, while the name of the standard promises the owner controls it.
  - Two consequences follow. Registration runs the same authority check, so a contract cannot create
    its own binding and the owner must call `register`; a contract that self-registers from a
    constructor or init hook needs a two-step deploy or should bind as `ACCOUNT`. And because the
    `owner()` probe fails closed with no self-authority to fall back on, `renounceOwnership()`
    permanently freezes the identity. That is intended.
  - This is an explicit opt-in chosen at bind time, and, like the rest of the `Binding`, the choice
    is immutable. `ACCOUNT` (value `5`) semantics are entirely unchanged: binding as `5` still means
    no `owner()`, role, or balance route in, and the adapter still makes zero external authority
    calls on that branch. A contract that wants owner-driven management opts in by binding as `6`
    instead of `5`.
  - The `owner()` probe is a fail-closed `STATICCALL`. The typed interface declares `owner()` as
    `view`, so an authority check can never reenter. A revert (no assumed selector), returndata that
    is not exactly 32 bytes, dirty upper bits above the 160-bit address, or a zero owner each grant
    no external authority, and a zero owner therefore never matches a zero `account`. None of these
    outcomes leaves any authority behind, since there is no contract-self fallback.
  - Owner authority is **dynamic**: it follows ownership transfer. A new owner gains authority over
    agents bound before it took over, and the previous owner loses it. This is the deliberate
    contrast with value `5`, whose bound address is the permanent sole controller. Under EIP-173
    and the marketplace convention, many contracts expose `owner()` only as a royalties or
    collection-metadata admin, often a stale deployer EOA, so this authority is never assumed.
    It exists only where a contract chose value `6`.
  - For all three account-level standards the `Binding` itself stays immutable, with deliberately no
    revoke or unbind API.
    Ownership transfer moves who may write; it never rebinds or unbinds an agent.
  - `tokenId` MUST be `0` for value `6` as well, enforced at both authority choke points and
    reverting with the same `NonZeroTokenIdForAccount(boundAddress, tokenId)` error. Value `6`
    also stays outside the single-owner set, so it gets no ownerless-collection window. It does have
    a delegate.xyz route, added later in this release train and described above.
  - `registrationHash` is unchanged and the standard remains excluded from it, so a contract at
    `(X, 0)` claiming as ERC-721 token `#0`, `ACCOUNT`, and `CONTRACT_OWNABLE` aliases all three
    onto one identity with one current claim, resolved by the latest
    `CounterfactualAgentRegistered.standard` in log order. `AgentBound` and the counterfactual event
    layouts are unchanged; `6` is only a new value in the existing `uint8` field.
- Admin contract bindings. `CONTRACT_ADMIN` is appended to `TokenStandard` as value `7`; values
  `0`-`6` are unchanged, so stored bindings and indexed history keep their meaning.
  - Authority is any holder of the bound contract's `DEFAULT_ADMIN_ROLE`, which is `bytes32(0)`, and
    nobody else. The bound contract itself has no authority, as with value `6`. It exists for an
    AccessControl contract that exposes no `owner()`, which could otherwise only bind as value `5`
    and route every identity update through its own code. It also closes an asymmetry:
    `setPrimaryAgentFor` has always accepted a `DEFAULT_ADMIN_ROLE` holder, so before this an admin
    could set a contract's primary agent while being unable to manage an identity bound to it.
  - The `hasRole(bytes32,address)` probe is a fail-closed `STATICCALL`. A revert, returndata whose
    length is not exactly 32 bytes, or a zero word each grant nobody. Any non-zero word counts as
    holding the role, which is deliberately more permissive than the value-6 address probe: nothing
    is being extracted from the word, so a non-canonical `true` from an honest implementation is
    accepted rather than reverted.
  - Role membership is read on every call, so granting or revoking the role takes effect in the same
    transaction. Registration runs the same authority check, so an admin must create the binding and
    the contract cannot register itself.
  - No delegate.xyz route, by design rather than omission. Delegation requires one delegator to ask
    the registry about, and a role is a membership predicate that many addresses can satisfy and none
    can enumerate, so there is no well-defined delegator to name.
  - `tokenId` MUST be `0`, enforced at both authority choke points with the same
    `NonZeroTokenIdForAccount(boundAddress, tokenId)` error. Value `7` stays outside the
    single-owner set, so it gets no ownerless-collection window. `registrationHash` is unchanged and
    still excludes the standard, and `7` is only a new value in the existing `uint8` field, so no
    event signature or topic moves.
- Full ERC-8004 `register` now accepts the same temporary
  ownerless collection authority as unsigned counterfactual writes: the directly calling
  ERC-721/ERC-1155F/ERC-6909F token contract may register its own id while `ownerOf(tokenId)`
  reverts or returns canonical `address(0)`. Minting to a non-collection owner closes the window;
  the buyer/controller then receives ordinary binding control. Plain ERC-1155/ERC-6909 remain
  positive-balance controlled.

### Changed

- Generalized `_requireCounterfactualControl` to the shared `_requireTokenAuthority` helper and
  routed both full registration and every unsigned counterfactual write through it so their
  ownerless-collection rule cannot drift.
- Registration never writes a primary-agent pointer. An authorized mint flow that wants the buyer's
  primary uses `register`, mints, then calls `setPrimaryAgentFor(buyer, agentId)`; otherwise the buyer
  sets it separately with `setPrimaryAgent`.
- Split reverse resolution into two independent systems:
  - full ERC-8004: `uint256` `setPrimaryAgent`, `primaryAgentOf`, full-only events, and
    `primaryAgentNonces`;
  - counterfactual: new `set/clear/primaryCounterfactualAgent...` APIs, coordinate-bearing
    `PrimaryCounterfactualAgent...` events.
- Removed the ambiguous `nonces(address)` API and old `setPrimaryAgent(bytes32)` selector.
  `PrimaryAgentSet` and `PrimaryAgentSetWithSig` now index a `uint256`, changing their topic0.
- Counterfactual hashes now use
  `keccak256(abi.encode(interoperableAddress(address(adapter)),
  boundAddress, tokenId))`. The adapter proxy is a full ERC-7930 v1 / CAIP-350 `eip155`
  Interoperable Address containing the local chain and raw 20-byte proxy address. `boundAddress`
  deliberately remains a naked EVM `address`; chain binding comes from the adapter Interoperable
  Address alone. `interoperableAddress(address)` exposes that encoding, while `chainIdentifier()`
  exposes its AddressLength=0 chain-only variant. This uses
  `abi.encode(bytes,address,uint256)`, not packed encoding, and is a hard hash cutover with no
  legacy fallback.
- Full-system signatures use the `SetPrimary8004Agent` and `ClearPrimary8004Agent` EIP-712
  types. The standard numeric-EVM `EIP712Domain` is unchanged.

This ownerless full-registration change adds no public selector, storage slot, event ABI,
counterfactual payload-version change, or `@custom:version` bump.

Account-level bindings add no public selector, storage slot, or `@custom:version` bump either.
`registrationHash`, the counterfactual event schema, and `version == 1` are unchanged;
`AgentBound` keeps its layout with `standard` indexed, and `CounterfactualAgentRegistered`, the
only counterfactual event carrying a standard, keeps its layout with `standard` non-indexed.
`ACCOUNT` and `CONTRACT_OWNABLE` are only new values in the existing `uint8` field. Because the
standard is excluded from `registrationHash`, any two standards claiming the same `(boundAddress,
tokenId)` alias onto one hash; a contract at `(X, 0)` claiming its ERC-721 token `#0`, `ACCOUNT`,
and `CONTRACT_OWNABLE` is the worked example. That is accepted and documented. Hashing the standard would break
every existing hash. The claims are deliberately one identity with one current claim, and indexers
read the latest `CounterfactualAgentRegistered.standard` in log order to see which claim wins.

### Removed

- Removed the unreleased signature-based counterfactual registration APIs
  `counterfactualRegisterWithSig(...)` and
  `counterfactualRegisterAndSetPrimaryWithSig(...)`. Register-at-mint now uses the unsigned
  counterfactual register family: the collection calls the adapter directly while the
  ERC-721/ERC-1155F/ERC-6909F id is ownerless, then mints.
- Removed their EIP-712 typehashes, payload structs, metadata hashing and verification helpers,
  bundled registration-event helper, CF-only `ExpirationTooFar` error, tests, and typed-data
  fixture content.
- Removed the unreleased signed counterfactual-primary APIs and nonce getter, their EIP-712
  typehashes, `WithSig` events, tests, and fixture:
  `setPrimaryCounterfactualAgentWithSig`, `clearPrimaryCounterfactualAgentWithSig`, and
  `primaryCounterfactualAgentNonces`. Full-system signed primary reverse-resolution remains
  available through `setPrimaryAgentWithSig` and `clearPrimaryAgentWithSig`.

### Storage and migration

- Appended `_primaryAgent` (slot 2), `_primaryCounterfactualAgent` (slot 3), and
  `_primaryAgentNonces` (slot 4) directly after the live fields. The unreleased
  0.0.9-0.0.13 layouts consume no
  compatibility slots because they were never deployed.
- There is no production primary-agent state to migrate and no heuristic migration or
  reinitializer. Both new systems begin unset after a direct live-baseline upgrade.
  Production rollout must still prove zero legacy primary events and stop if that gate fails,
  because a failure would contradict the audited baseline.

## [0.0.13] - Unreleased

Source version. Not deployed. No storage migration or initializer.

### Added
- Ownerless collection authority for every existing **unsigned** counterfactual write on
  ERC-721, ERC-1155F, and ERC-6909F. When the directly calling `boundAddress` has deployed
  code and `ownerOf(tokenId)` reverts or returns canonical `address(0)`, it may emit registration,
  URI, metadata, batch metadata, wallet-set, and wallet-unset events before mint. Events keep
  `emitter = boundAddress`; multiple emissions remain allowed and latest log order wins.
- Fail-closed `ownerOf` response validation. A successful result must be exactly one canonical
  ABI address word; wrong-length or dirty-upper-bit results revert `InvalidOwnerOfResponse`.

### Changed
- `_requireValidTokenContract` now rejects addresses without deployed code, preventing an EOA
  from masquerading as an ownerless collection. Constructor-time adapter calls are unsupported.
  (Renamed `_requireValidBoundAddress` in v0.0.16, which makes the code test standard-aware: every
  standard keeps it except `ACCOUNT`, so constructor-time calls became supported for that one.)
- After mint, collection calls fall back to the unchanged owner/delegate controller model. A burn
  can reopen the collection-only window because “ownerless” means no current owner and the adapter
  deliberately stores no historical-existence bit.
- Plain ERC-1155 and ERC-6909 remain positive-balance controlled.

There are no new public selectors, storage slots, registration-hash changes, counterfactual event
topics, payload-version changes, or EIP-712 changes in `0.0.13`.

## [0.0.12] - Unreleased

Source version. Not deployed. No storage/layout change (slots 0/1/2/3 identical
to `0.0.11`).

### Added
- **`registerAndSetPrimary(TokenStandard standard, address boundAddress, uint256 tokenId, string agentURI) -> uint256 agentId`**
  — a caller-paid, no-signature/no-relayer convenience wrapper: it runs the canonical `register`
  body (empty metadata) and then records the freshly minted `agentId` as the **caller's own** primary
  agent, in one transaction. Equivalent to calling `register(...)` then `setPrimaryAgent(bytes32(agentId))`
  yourself: identical token-control authorization, `AgentBound` event, and returned id, plus a
  standard `PrimaryAgentSet(caller, bytes32(agentId), caller)`. No new storage, authorization, or event
  families.
  (Removed again in `0.0.16` before any deployment; see that section for why.)

### Changed
- Refactor only: the shared register body helper is renamed `_registerImpl` → `_register` (no
  `nonReentrant`), called by both `register` overloads and the new wrapper. `register` behavior,
  authorization, events, and return value are unchanged.

## [0.0.11] - Unreleased

Source version. Not deployed. Adds a gasless (relayer-submittable) EIP-712
surface for the primary-agent reverse pointer. No storage migration: `nonces`
is appended at slot 3 and slots 0/1/2 are byte-identical to `0.0.10`.

> Security gate: this is a new authorization / EIP-712 / replay / ERC-1271
> surface. Per the design, it requires a sol-auditor pass, an independent
> security-adapter review, and CSO reconciliation against the frozen diff/ABI
> before any implementation deploy or Safe upgrade. Not shippable on tests alone.

### Added
- **Signed (account-self) primary-agent surface** (`IERC8004AdapterPrimaryAgent`):
  - `setPrimaryAgentWithSig(address account, bytes32 agentId, uint256 deadline, bytes signature)`
    and `clearPrimaryAgentWithSig(address account, uint256 deadline, bytes signature)` — any
    relayer submits a signature by `account` itself (EOA `ecrecover` or the account's ERC-1271
    policy, via `SignatureChecker`). Strictly account-self: there is **no** owner/admin/controller
    signature route (that authority stays on the paid `setPrimaryAgentFor` / `clearPrimaryAgentFor`).
  - `nonces(address)` — one monotonic nonce per account, **shared** by signed set/clear operations,
    embedded in the signed struct (not a calldata argument) and consumed once per success, so a used
    signature cannot be replayed and any op pre-signed against the same nonce is invalidated.
  - `MAX_PRIMARY_AGENT_SIGNATURE_LIFETIME = 30 minutes` deadline cap (a deadline equal to the current
    block timestamp is still valid); errors `SignatureDeadlineTooFar` / `SignatureExpired` and
    `InvalidSignature`.
  - Audit events `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)` and
    `PrimaryAgentClearedWithSig(account, relayer, nonce)`. The legacy `PrimaryAgentSet` /
    `PrimaryAgentCleared` events are unchanged and still emitted first with `setBy` / `clearedBy` =
    `msg.sender` (the relayer); indexers act on the legacy event and use the signed event only for
    provenance (authorization = EIP-712, relayer, nonce).
  - `agent-binding` semantics unchanged: `agentId == 0` is a valid claim; the all-ones sentinel is
    reserved and reverts `PrimaryAgentIdReserved`. The paid setters and slot-2 complement encoding
    are untouched.
  - Consumer fixtures (EIP-712 type strings, viem typed-data, and example calldata) published under
    [`docs/fixtures/`](./docs/fixtures/adapter-primaryagent-withsig.md).

## [0.0.10] - Unreleased

Source version. Not deployed. Supersedes the `0.0.9` primary-agent semantics
below (neither `0.0.9` nor `0.0.10` is live on any chain).

### Changed
- **Primary-agent storage is now complement-encoded** (`IERC8004AdapterPrimaryAgent`).
  The `_primaryAgent` mapping still lives at slot 2 as `mapping(address => bytes32)`
  — the storage layout is byte-identical (slots 0/1/2 unchanged, verified via
  `forge inspect ... storageLayout`) — but it now stores the **bitwise complement**
  of the id (`~agentId`) rather than the raw id.
  - **Agent id `0` is now a representable primary agent.** An unwritten slot is
    zero, which complements to the all-ones sentinel, so "unwritten" reads as
    "unset" for free while every real id — `0` included — round-trips. The old
    `0.0.9` design treated `agentId == 0` as a clear, so id `0` could not be set.
  - New sentinel `PRIMARY_AGENT_UNSET = bytes32(type(uint256).max)` (all ones).
    `primaryAgentOf(account)` returns it when the account has never set an id or
    has cleared it (previously it returned `bytes32(0)`).
  - Setters no longer treat `0` as a clear. Removal is explicit via new
    `clearPrimaryAgent()` / `clearPrimaryAgentFor(address)`, which emit a
    dedicated `PrimaryAgentCleared(account, clearedBy)` event.
  - `setPrimaryAgent` / `setPrimaryAgentFor` revert `PrimaryAgentIdReserved`
    when passed the all-ones sentinel id (it would complement to zero and alias
    "unset").
  - `PrimaryAgentSet` is now emitted only for real-id writes; clears emit
    `PrimaryAgentCleared`. Authorization for the `*For` calls is unchanged
    (account itself, `owner()` / `getOwner()`, or `DEFAULT_ADMIN_ROLE`).

## [0.0.9] - Unreleased

Source version. Not deployed. Its primary-agent semantics are superseded by
`0.0.10` above; the description below is retained as historical record.

### Added
- **Primary-agent reverse resolution** (`IERC8004AdapterPrimaryAgent`): an
  `address => bytes32 agentId` mapping on the adapter that resolves a wallet
  address (or any address recorded in agent metadata) to the agent it claims to
  belong to, on this chain. Combined with the agent's own wallet claim (ERC-8004
  `agentWallet` or the counterfactual `CounterfactualAgentWalletSet` event), a
  consumer can verify that a wallet and an agent mutually point at each other.
  - The id is an ERC-8004 registry token id (small, incremental, stored as
    `bytes32(id)`) or a 32-byte counterfactual `registrationHash`. The two id
    spaces do not collide, so a single mapping holds both.
  - `setPrimaryAgent(bytes32 agentId)` sets the caller's own id;
    `setPrimaryAgentFor(address account, bytes32 agentId)` sets an account's id
    when the caller is the account, its `owner()` / `getOwner()`, or a holder of
    its `DEFAULT_ADMIN_ROLE`; `primaryAgentOf(address)` reads it. `agentId == 0`
    clears. Emits `PrimaryAgentSet(account, agentId, setBy)`.
  - The control check is a defensive static call that tolerates non-conforming
    return data (wrong length or dirty bits) without reverting, and is
    account-scoped: a contract that misreports its controller can only affect its
    own mapping entry. New storage `_primaryAgent` is appended after `_bindings`
    to preserve the upgrade layout. No registry writes, no effect on bindings.

## [0.0.8] - Unreleased

Source version. Not deployed.

### Changed
- **`registrationHash` no longer includes the token standard**, reverting the
  unreleased `0.0.6` change below and restoring the hash to the form that is live
  on Ethereum mainnet, Base, and Sepolia. The counterfactual identity is
  `keccak256(chainId, adapter, boundAddress, tokenId)`; the `TokenStandard` is
  dropped from the hash preimage and from the `registrationHash(boundAddress,
  tokenId)` / internal `_registrationHash` signatures (and the
  `IERC8004AdapterCounterfactual` interface).

  The deployed counterfactual implementation (commit `a20035c`) never bound the
  standard. It was added only in the unreleased `0.0.6` source (`3bcef29`) and
  carried into `0.0.7`; neither is deployed. Verified: the no-standard preimage
  reproduces the live Base smoke value `registrationHash(0xdEaD, 0) ==
  0x723bd0…875a3faa`, so **no on-chain `registrationHash` value changes** — this
  only re-aligns the source with production.

  A token therefore has one identity regardless of which token interface it is
  registered through. The standard is still validated at registration via the
  ownership check, bound into the signed EIP-712 payload, and carried in every
  counterfactual event, so authorization and indexing are unaffected. Event ABIs
  are unchanged (`topic[0]` and `COUNTERFACTUAL_PAYLOAD_VERSION` stay `1`).
- Trade-off: a contract exposing the same `tokenId` as distinct assets under two
  different standards resolves to one identity. Such contracts are out of scope.

## [0.0.7] - Unreleased

Source version. Not deployed. Requires a fresh security review and audit pass
before any multisig deploy.

### Added
- Token standard enum values `ERC1155F` (`0x03`) and `ERC6909F` (`0x04`) for
  non-fungible ERC-1155/ERC-6909 tokens that expose `ownerOf(uint256)` per the
  ERC-8276 (Non-Fungible Multi-Token `ownerOf`) profile, in review as
  Ethereum/ERCs PR #1767. These standards use single-owner control (`ownerOf`
  plus delegate.xyz on unsigned/controller-gated paths); plain
  ERC-1155/ERC-6909 remain balance-based.

### Changed (security review)
- Reserved the `cf-registration` key on the **canonical** write surface as well:
  `register`, `setMetadata`, and `setMetadataBatch` now reject it, matching the
  counterfactual surface. Previously the key was reserved only on counterfactual
  writes, so a controller could fabricate a promotion back-link on the canonical
  surface. The key has no legitimate on-chain writer.
- Removed an unreachable internal helper (`_requireNotReservedBindingKey`) whose
  name was one character from a live helper; canonical writes now route through
  the shared counterfactual-key guard.

## [0.0.6] - Unreleased

Source version. Safe TX payloads prepared 2026-05-20
([`deployments/`](./deployments)) but not yet executed.

### Added
- `bindExisting`: pull an already-minted ERC-8004 `agentId` into adapter
  management against an external ERC-721/1155/6909 token, using a
  two-transaction approval model. Preserves the existing `agentURI` and
  non-binding metadata; overwrites only the reserved `agent-binding` key.
  (Removed in `0.0.16` before any deployment; see that section for why.)
- Counterfactual payload versioning: every counterfactual event carries a
  `uint8 version` first non-indexed field (baseline `1`), so indexers can detect
  ABI cutovers.
- Reserved `cf-registration` metadata key on the counterfactual write surface,
  preventing a fabricated promotion back-link before any on-chain mint.

### Changed
- `registrationHash` now binds the token `standard` in addition to chain id,
  adapter address, token contract, and token id.
  **Reverted in `0.0.8`; never deployed. The live implementations keep the
  original standard-free hash `keccak256(chainId, adapter, boundAddress, tokenId)`.**

### Errors
- `AlreadyBound`, `NotAgentOwner`, `AgentTransferNotApproved`,
  `BoundAddressIsRegistry`.

## Earlier history (pre-version-numbering)

These upgrades predate the `@custom:version` tag and were tracked by dated
deployment reports in [`deployments/`](./deployments). Dates are deployment or
report dates, not source-tag dates.

### 2026-05-16 — delegate.xyz v2 ERC-721 delegate support (live on Sepolia only)
- Adds hot/cold control for ERC-721 bindings: a wallet holding a delegate.xyz v2
  delegation from the current owner can drive the agent while the NFT stays in
  cold storage. Fails closed to direct ownership if the registry has no code.
- **Per-chain status (verified 2026-05-23):**
  - **Sepolia: live.** Implementation `0x31a68E5b…` deployed, and the proxy was
    upgraded to it. delegate.xyz support is active here.
  - **Base: not live.** Implementation `0x0e30C112…` was deployed and verified,
    but the proxy was not upgraded (still on the 2026-05-15 counterfactual impl
    `0x0f81bd4E…`).
  - **Mainnet: not live.** Implementation never deployed (the deploy was deferred
    for gas; the proxy still runs `0xa6D23f27…`).
- The 2026-05-16 deployment report records the implementation deploys; the
  Sepolia proxy upgrade was performed afterward. Safe TX payloads
  (`deployments/2026-05-16-delegate-xyz-safe-tx-*.json`) were prepared for the
  Base/mainnet upgrades but not executed. See
  `deployments/2026-05-16-delegate-xyz-implementation-deployment-report.md`.

### 2026-05-15 — ownership transferred to Safe multisig
- Adapter `owner()` moved from the deployer EOA to a Safe v1.4.1 multisig at the
  same address (`0x03302Df40186D9B85faEA4fbb6cC5da028B23149`) on Mainnet, Base,
  and Sepolia. The transfer report records a threshold of 2 at transfer time; the
  Safe config has since evolved. Current on-chain config (verified 2026-05-23):
  **Mainnet 3-of-4**, **Base 2-of-4**, **Sepolia 2-of-4**. See
  `deployments/2026-05-15-ownership-transfer-to-safe-report.md`, and confirm the
  live threshold/owners on-chain before relying on it. Any 0.0.6 / 0.0.7 deploy on
  mainnet now needs 3 of 4 signatures.

### 2026-05-15 — counterfactual registration family + full event coverage + reentrancy guards (current live implementation)
- Emit-only counterfactual register family (`counterfactualRegister` plus five
  `counterfactual*` setters): mirrors the on-chain register surface but emits
  events only, keyed by `registrationHash(chainid, adapter, boundAddress, tokenId)`
  (the `standard` field was added later in 0.0.6).
- Full on-chain event coverage: every state-mutating external function emits one
  adapter-level event (`AgentURISet`, `MetadataSet`, `AgentWalletSet`,
  `AgentWalletUnset`, `BindingMetadataRewritten`, alongside the existing
  `AgentBound`, `MetadataBatchSet`, `IdentityRegistryUpdated`).
- OZ v5 `ReentrancyGuard` (ERC-7201 namespaced) on every state-mutating external
  function. Rolled out to all three proxies via executed `upgradeToAndCall`. See
  `deployments/2026-05-15-counterfactual-upgrade-report.md`.

### 2026-05-07 — ERC-8004 interface coverage upgrade
- Aligned the adapter with the full ERC-8004 interface surface: direct view
  forwarders `getMetadata` / `getAgentWallet` / `ownerOf` / `tokenURI`
  (`IERC8004IdentityRecord`), the `register(string)` / `register()` overloads, the
  read/registration interface split, and a
  `register(standard, boundAddress, tokenId, agentURI)` convenience overload.
  No new storage. See `deployments/2026-05-07-erc8004-coverage-upgrade-report.md`.

### 2026-04-30 — ERC-8217 binding-metadata migration
- The `agent-binding` metadata value became the 20-byte binding-contract
  (adapter) address, with token coordinates read from `bindingOf(agentId)`. See
  `deployments/2026-04-30-erc8217-upgrade-report.md` and
  `deployments/2026-04-30-erc8217-migration-plan.md`.

### 2026-04-05 — initial deployment (Mainnet, Base, Sepolia)
- First Adapter8004 release: `register`, `setAgentURI`, `setMetadata`,
  `setMetadataBatch`, `setAgentWallet`, `unsetAgentWallet`, `bindingOf`,
  `isController`, over an `ERC1967Proxy` with a UUPS upgradeable implementation.
  See `deployments/2026-04-05-deployment-report.md`.

[0.0.7]: https://github.com/unruggable-labs/adapter
[0.0.6]: https://github.com/unruggable-labs/adapter
