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

Numbered source versions `0.0.6`-`0.0.13` are not live on any chain. In
particular, the primary-agent layouts in `0.0.9`-`0.0.13` are not production
upgrade baselines. Re-verify the EIP-1967 implementation slot before relying
on this summary; see the
[last-deployed baseline audit](./deployments/upgrade-baseline-from-last-deployed.md).

## [0.0.14] - Unreleased

Breaking source release. Not deployed. Upgrades directly from the active
May 15 counterfactual implementation on Mainnet/Base and the active
delegate.xyz implementation on Sepolia. Both deployed baselines have only
regular slots 0 and 1. Uses empty `upgradeToAndCall` data (not an initializer
or reinitializer payload).
The primary-agent designs in unreleased `0.0.9` through `0.0.13` are superseded.

### Added

- Contract bindings. `CONTRACT` is appended to `TokenStandard` as value `5`; values `0`-`4` are
  unchanged, so stored bindings and indexed history keep their meaning. Values `0`-`4` name a token
  within a contract; `CONTRACT` names any deployed contract itself, token or not. An ERC-20 claiming
  its own identity is the motivating example and uses `CONTRACT` like any other contract — there is
  no ERC-20-specific standard value. (ERC-20Agent is a separate metadata profile layered on top, not a
  binding standard.)
  - `tokenId` MUST be `0`: a contract-level binding has exactly one canonical coordinate. Any other
    id reverts the new `NonZeroTokenIdForContract(tokenContract, tokenId)` error rather than being
    coerced, enforced at both authority choke points, so it covers `register`,
    `registerAndSetPrimary`, `bindExisting`, and every unsigned counterfactual writer.
  - The controller is the bound `tokenContract` itself and nothing else — no holder, delegate,
    optional `owner()`, or adapter admin has authority. The adapter probes neither `ownerOf` nor
    either `balanceOf` shape; control is `msg.sender == tokenContract`, so a contract with no token
    interface at all binds exactly like one that has one.
  - Unlike the transient ERC-721/ERC-1155F/ERC-6909F direct-collection window, which closes on mint
    and can reopen on burn, a contract-level binding has no token whose ownership could change hands,
    so its authority window never closes. `CONTRACT` is deliberately excluded from the single-owner
    set: no ownerless probe, no delegate.xyz route.
  - The adapter's immediate EVM caller must be `tokenContract`. A router, forwarder, or multicall
    contract that calls the adapter itself fails, because the adapter sees that contract as
    `msg.sender`. An external owner or governance address may instead call an entry point on the
    bound contract, which then makes the outbound adapter call (the planned reference pattern). A
    constructor call is rejected — deployed runtime code is required. `delegatecall` into
    `Adapter8004` is unsupported and dangerous: it is a UUPS implementation with its own storage
    layout, not a library. `bindExisting` additionally requires the bound contract to own the
    ERC-8004 agent and to have approved the adapter. `registerAndSetPrimary` records the bound
    contract's own primary agent.
  - Permanent authority is worth nothing without a repeatable outbound path to the adapter. A
    contract that cannot call out cannot bind at all; one with a single post-deployment hook binds
    once and then freezes. Repeatable management needs a governance-gated, upgradeable, or
    pass-through outbound path.
  - Post-bind, the mutable registry fields are bound-contract-only and its latest write wins. The
    `Binding` stays immutable with deliberately no revoke or unbind API — register a fresh ERC-8004
    identity instead. Counterfactual claims likewise have no whole-claim tombstone: later events
    from the contract supersede earlier ones by last-event-wins, and wallet unset is field-level.
- Full ERC-8004 `register` (including `registerAndSetPrimary`) now accepts the same temporary
  ownerless collection authority as unsigned counterfactual writes: the directly calling
  ERC-721/ERC-1155F/ERC-6909F token contract may register its own id while `ownerOf(tokenId)`
  reverts or returns canonical `address(0)`. Minting to a non-collection owner closes the window;
  the buyer/controller then receives ordinary binding control. Plain ERC-1155/ERC-6909 remain
  positive-balance controlled, and `bindExisting` still requires ordinary current control.

### Changed

- Generalized `_requireCounterfactualControl` to the shared `_requireTokenAuthority` helper and
  routed both full registration and every unsigned counterfactual write through it so their
  ownerless-collection rule cannot drift.
- `registerAndSetPrimary` remains caller-scoped: when a collection uses the ownerless window, it
  records the new full agent as the collection's primary. An authorized mint flow that wants the
  buyer's primary uses `register`, mints, then calls `setPrimaryAgentFor(buyer, agentId)`; otherwise
  the buyer sets it separately.
- Split reverse resolution into two independent systems:
  - full ERC-8004: `uint256` `setPrimaryAgent`, `primaryAgentOf`, full-only events, and
    `primaryAgentNonces`;
  - counterfactual: new `set/clear/primaryCounterfactualAgent...` APIs, coordinate-bearing
    `PrimaryCounterfactualAgent...` events.
- `registerAndSetPrimary` writes only the full mapping.
- Removed the ambiguous `nonces(address)` API and old `setPrimaryAgent(bytes32)` selector.
  `PrimaryAgentSet` and `PrimaryAgentSetWithSig` now index a `uint256`, changing their topic0.
- Counterfactual hashes now use
  `keccak256(abi.encode(interoperableAddress(address(adapter)),
  tokenContract, tokenId))`. The adapter proxy is a full ERC-7930 v1 / CAIP-350 `eip155`
  Interoperable Address containing the local chain and raw 20-byte proxy address. `tokenContract`
  deliberately remains a naked EVM `address`; chain binding comes from the adapter Interoperable
  Address alone. `interoperableAddress(address)` exposes that encoding, while `chainIdentifier()`
  exposes its AddressLength=0 chain-only variant. This uses
  `abi.encode(bytes,address,uint256)`, not packed encoding, and is a hard hash cutover with no
  legacy fallback.
- Full-system signatures use the `SetPrimary8004Agent` and `ClearPrimary8004Agent` EIP-712
  types. The standard numeric-EVM `EIP712Domain` is unchanged.

This ownerless full-registration change adds no public selector, storage slot, event ABI,
counterfactual payload-version change, or `@custom:version` bump.

Contract bindings add no public selector, storage slot, or `@custom:version` bump either.
`registrationHash`, the counterfactual event schema, and `version == 1` are unchanged;
`AgentBound` keeps its layout with `standard` indexed, and `CounterfactualAgentRegistered` — the
only counterfactual event carrying a standard — keeps its layout with `standard` non-indexed.
`CONTRACT` is only a new value in the existing `uint8` field. Because the standard is excluded from
`registrationHash`, any two standards claiming the same `(tokenContract, tokenId)` alias onto one
hash; a contract at `(X, 0)` claiming both its ERC-721 token `#0` and `CONTRACT` is the worked
example. That is accepted and documented — hashing the standard would break
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
  ERC-721, ERC-1155F, and ERC-6909F. When the directly calling `tokenContract` has deployed
  code and `ownerOf(tokenId)` reverts or returns canonical `address(0)`, it may emit registration,
  URI, metadata, batch metadata, wallet-set, and wallet-unset events before mint. Events keep
  `emitter = tokenContract`; multiple emissions remain allowed and latest log order wins.
- Fail-closed `ownerOf` response validation. A successful result must be exactly one canonical
  ABI address word; wrong-length or dirty-upper-bit results revert `InvalidOwnerOfResponse`.

### Changed
- `_requireValidTokenContract` now rejects addresses without deployed code, preventing an EOA
  from masquerading as an ownerless collection. Constructor-time adapter calls are unsupported.
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
- **`registerAndSetPrimary(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI) -> uint256 agentId`**
  — a caller-paid, no-signature/no-relayer convenience wrapper: it runs the canonical `register`
  body (empty metadata) and then records the freshly minted `agentId` as the **caller's own** primary
  agent, in one transaction. Equivalent to calling `register(...)` then `setPrimaryAgent(bytes32(agentId))`
  yourself: identical token-control authorization, `AgentBound` event, and returned id, plus a
  standard `PrimaryAgentSet(caller, bytes32(agentId), caller)`. No new storage, authorization, or event
  families.

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
  `keccak256(chainId, adapter, tokenContract, tokenId)`; the `TokenStandard` is
  dropped from the hash preimage and from the `registrationHash(tokenContract,
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
- Counterfactual payload versioning: every counterfactual event carries a
  `uint8 version` first non-indexed field (baseline `1`), so indexers can detect
  ABI cutovers.
- Reserved `cf-registration` metadata key on the counterfactual write surface,
  preventing a fabricated promotion back-link before any on-chain mint.

### Changed
- `registrationHash` now binds the token `standard` in addition to chain id,
  adapter address, token contract, and token id.
  **Reverted in `0.0.8`; never deployed. The live implementations keep the
  original standard-free hash `keccak256(chainId, adapter, tokenContract, tokenId)`.**

### Errors
- `AlreadyBound`, `NotAgentOwner`, `AgentTransferNotApproved`,
  `InvalidTokenContractIsRegistry`.

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
  events only, keyed by `registrationHash(chainid, adapter, tokenContract, tokenId)`
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
  `register(standard, tokenContract, tokenId, agentURI)` convenience overload.
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
