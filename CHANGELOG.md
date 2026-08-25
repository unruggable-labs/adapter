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
- `walletUBIOf(address)` reverts on all three, so no live
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

Adds no storage slot and upgrades from the same deployed baselines with empty
`upgradeToAndCall` data. That holds for the attestation surface below as much as
for the identifier change: the whole subsystem is emit-only, so it adds no slot
at all. It does **free** one: `identityRegistry` became `immutable`, so slot 0
is now dead and permanently reserved, and regular storage begins at slot 1.
Recorded under Removed below.

### Added

- **An emit-only attestation surface for counterfactual identities.** Three
  external functions, two events, two errors, five published type constants:

  ```
  attest(bytes32 attestationType, bytes32 cfid, bytes32 variant, bytes data)
  confirmAdditionalAccount(bytes32 cfid)
  revoke(bytes32 attestationId)
  ```

  An attestation is a public statement about a UBI.
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
  preimage to this adapter on this chain, exactly as `bindingHashFor` binds.
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
  because a type is what an enum is for, because `Standard` in this same
  contract is already an enum, and because the contract is upgradeable, so the
  cost of admitting a type is an upgrade the owner can already make. The open
  namespace is the capability given up, knowingly.

  `UNSPECIFIED` occupies zero because Solidity enums start there. Without it the
  first real type would be the value a default-initialized variable carries,
  which is exactly what `AttestationTypeZero` exists to reject; with it the guard
  keeps working unchanged in meaning.

  **The numbering is identity-critical**, in the same way `Standard`'s
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

### Added

- **Two combined setters that close the wallet loop in one call.**

  ```
  setAgentWalletAndID(uint256 agentId, address newWallet, uint256 deadline, bytes signature)
  counterfactualSetAgentWalletAndUBI(Standard standard, address boundAddress, uint256 tokenId, address newWallet)
  ```

  Setting an agent's wallet and setting that wallet's id are two halves of one
  loop, and were two transactions by potentially two parties. Each new function
  does the forward write it already did, then sets the reverse pointer for
  `newWallet`, reusing the existing internal setters so the guards and events stay
  in one place. They emit exactly what both halves emit today rather than a
  combined event, so an indexer needs no new subscription and the existing
  projection keeps working. Parameter shapes match `setAgentWallet` and
  `counterfactualSetAgentWallet` exactly.

  **Authorization is unchanged from the forward call.** The caller proves control
  of the agent or the token, and nothing is required on the wallet side. Gating the
  reverse write on wallet-side control was considered and rejected: it would mean
  the caller is the wallet, who could already make both calls, which defeats the
  point. Verification happens at read time instead, where a reader checks the
  forward and reverse records agree, so a reverse pointer written to an unwilling
  wallet produces no false positive and that wallet overwrites it by calling
  `setWalletAgentID` itself. An existing designation on `newWallet` is overwritten,
  which is intended and tested.

  **The counterfactual call names the caller as the wallet.** It takes no
  `newWallet` parameter and uses `msg.sender`, which is what makes both halves
  legitimate without a signature: the caller proves control of the token, which
  authorizes the forward write, and the caller is the wallet, which supplies
  consent for the reverse one. A reader who finds the two records agreeing on this
  path therefore learns something real, that one actor was authorized on both
  sides. Naming a wallet other than the caller stays available as
  `counterfactualSetAgentWallet` plus `setWalletUBIFor`, two calls
  that prove correspondingly less.

  The registered `setAgentWalletAndID` keeps its `newWallet` parameter, because
  there the registry verifies a deadline-bounded EIP-712 signature scoped to that
  agent and wallet, so naming a wallet other than the caller is the point.

- **`bindingHashOf(uint256 agentId)`**, a view returning the counterfactual
  identity of an agent already registered through this adapter. It loads the
  stored binding and derives the identifier from those coordinates, so one call
  replaces `bindingOf` followed by `bindingHashFor` and the answer is the same
  value. Unknown agents revert `UnknownAgent` rather than returning zero, sharing
  one definition of unknown with `bindingOf` through a new private
  `_knownBinding` helper that both use, and which `_requireController` now uses
  too. No storage is added and no new copy of the formula exists; the derivation
  is the same internal helper `bindingHashFor` calls.

  It exists because attestations target counterfactual identifiers, and an
  integrator holding a registered `agentId` had to make two calls to find the one
  to attest against. The alternative considered was writing the reserved
  `cf-registration` key on every `register`, which was rejected: it would record
  something anyone can already compute from `bindingOf`, or from `AgentBound`
  which carries all three coordinates, at the cost of an external call and a cold
  `SSTORE` on the most-used function, and it would snapshot a formula that has
  already changed once in this version.

  The returned value is the same identity the counterfactual surface derives for
  those coordinates, so a registered agent and its counterfactual claims answer
  alike. Bindings are immutable, so the answer is fixed at registration and
  survives token transfers, which is the property that makes the view safe to rely
  on.

  **Every counterfactual function that derives an identity now returns it.** The
  five updaters, `counterfactualSetAgentURI`, `counterfactualSetMetadata`,
  `counterfactualSetMetadataBatch`, `counterfactualSetAgentWallet` and
  `counterfactualUnsetAgentWallet`, each already derived the hash for the event
  they emit and dropped it; each now returns it as `bindingHash`, the same name
  `counterfactualRegister` and the wallet-id setters use. No new derivation was
  added anywhere: the value was already being computed, so this costs nothing but
  the return data. Return types are not part of the selector, so existing callers
  dispatch identically and anything ignoring the return keeps ignoring it. The
  batch returns one hash because every entry lands on the one identity its
  coordinates name, which is what the code does rather than what the name implies.

  This closes the inconsistency where `counterfactualSetAgentWallet` and
  `counterfactualSetAgentWalletAndUBI` sat next to each other doing the same
  forward write and differed in return type.

  `counterfactualSetAgentWalletAndUBI` returns the `bytes32` identity it derived,
  matching its sibling `setWalletUBI`. It takes coordinates rather
  than a hash because `_requireTokenAuthority` checks authority against the token
  and keccak is one way, so a contract handed only a hash could not tell whether
  the caller controls what it names; returning the hash gives a caller that has
  just created an identity the handle without recomputing it or reading it back
  out of the log. `setAgentWalletAndID` returns nothing, which is already
  consistent: neither `setAgentWallet` nor `setWalletAgentID` returns anything, and
  the agent id was an input there.

  Neither function is added to an interface. `setAgentWallet` is declared on
  `IERC8004IdentityRecord` because it is an ERC-8004 record pass-through, which
  these compositions are not, and the counterfactual writers have never been
  declared in an interface at all.

### Changed

- **`TokenStandard` is renamed to `Standard`.** Three of the eight members are not
  token standards: `ACCOUNT` is a plain address, and `CONTRACT_OWNABLE` and
  `CONTRACT_ADMIN` are role checks on any contract. The struct field and the event
  parameter were already named `standard`. An enum canonicalizes to `uint8` in every
  signature, so selectors, `AgentBound` topics, the ERC-165 `interfaceId` and the
  binding hash preimage are all unchanged. Only the ABI's `internalType` hints move,
  from `enum IERC8217.TokenStandard` to `enum IERC8217.Standard`.

- **The primary-agent surface is renamed to the wallet-id surface.** The mapping
  exists because `wallet -> agentId` is one to many: ERC-8004's `setAgentWallet`
  makes every agent prove the wallet consented, so many agents can validly list
  the same wallet, and the reverse direction is ambiguous. This mapping is how the
  wallet picks which one speaks for it. "Primary" is the ENS word for that and
  only means anything to a reader who already knows ENS, so the names now say what
  the thing is.

  | Old | New |
  | --- | --- |
  | `setPrimaryAgent` | `setWalletAgentID` |
  | `setPrimaryAgentFor` | `setWalletAgentIDFor` |
  | `clearPrimaryAgent` | `clearWalletAgentID` |
  | `clearPrimaryAgentFor` | `clearWalletAgentIDFor` |
  | `primaryAgentOf` | `walletAgentIDOf` |
  | `PRIMARY_AGENT_UNSET` | `WALLET_AGENT_ID_UNSET` |
  | `setPrimaryCounterfactualAgent` | `setWalletUBI` |
  | `setPrimaryCounterfactualAgentFor` | `setWalletUBIFor` |
  | `clearPrimaryCounterfactualAgent` | `clearWalletUBI` |
  | `clearPrimaryCounterfactualAgentFor` | `clearWalletUBIFor` |
  | `primaryCounterfactualAgentOf` | `walletUBIOf` |
  | `PRIMARY_COUNTERFACTUAL_AGENT_UNSET` | `WALLET_UBI_UNSET` |

  Events, errors, private helpers and storage variables follow the same shape:
  `PrimaryAgentSet` and `PrimaryAgentCleared` become `WalletAgentIDSet` and
  `WalletAgentIDCleared`, `PrimaryCounterfactualAgentSet` and
  `PrimaryCounterfactualAgentCleared` become `WalletUBISet` and
  `WalletUBICleared`, `PrimaryAgentIdReserved` becomes
  `WalletAgentIDReserved`, and `PrimaryCounterfactualAgentHashReserved` becomes
  `WalletUBIReserved`. The two interface files are renamed to
  `IERC8004AdapterWalletAgentID.sol` and `IERC8004AdapterWalletUBI.sol`.

  **Every renamed function's selector and every renamed event's `topic0` changes.
  This is a full indexer and integrator cutover, on top of the one the registration
  hash change already forces.** Nothing resolves under an old name: a test probes
  each old selector and requires it to fail, with the renamed surface exercised in
  the same test so it cannot pass by everything having disappeared, and a second
  test requires none of the four old event topics to appear on the renamed paths.

  Function names take the `ID` capitalisation. Parameter names keep `agentId`,
  matching ERC-8004's own vocabulary, because those cross the boundary into the
  registry.

  The `For` suffix keeps the one meaning it has everywhere in this contract:
  acting on behalf of another account, gated by `_controlsAccount`. That is why the
  wallet is not in the base name. `setAgentIDForWallet` would have put a second
  sense of `For` into the name, and its delegated variant would have had to be
  `setAgentIDForWalletFor`.

### Changed

- **The counterfactual registration hash and the UBI are one concept with one
  name.** They were always the same value computed by the same formula, and the
  two names hid that. The identifier is determined by the coordinates alone, so it
  exists whether or not an agent is ever registered; registering adds an agent id
  alongside the UBI rather than creating it. The documentation now reads as one
  concept throughout rather than as one concept under two names.

  Two views are renamed, so **both selectors change**. They were renamed twice
  within this version, first onto the UBI vocabulary and then onto the mechanism
  name they carry now, so the full chain is:

  | Original | Intermediate | Final | Selector |
  |---|---|---|---|
  | `registrationHashOf(uint256)` | `ubiOf(uint256)` | `bindingHashOf(uint256)` | `0xda1b4b75` → `0x509e06dd` → `0x30b7f986` |
  | `registrationHash(uint8,address,uint256)` | `ubiFor(uint8,address,uint256)` | `bindingHashFor(uint8,address,uint256)` | `0xdb667f67` → `0x266224ca` → `0x3723bc92` |

  Only the final column ships; the intermediate names never left this branch and
  are recorded so a reviewer reading the branch history can follow it.

  `bindingHashOf` takes an agent id and answers for a registered agent;
  `bindingHashFor` takes raw coordinates and answers for anything, registered or
  not. They return the same value for the same binding, which is the point. The
  internal helpers moved with them, to `_bindingHash` and `_bindingHashFrom`.

  **The final names split two jobs that one word was doing.** `bindingHash` names
  the mechanism and is what the code calls it, sitting next to `bindingOf` so the
  pair explains itself: one returns the `Binding`, the other returns the hash of
  the same thing. UBI names the value that mechanism produces and stays the citable
  noun in ERC-8217 and in prose. This is the ENS shape, where `namehash` is the
  mechanism and `node` is the value. The acronym is therefore not retired, it is
  confined to the place where it does work, and the `bytes32 ubi` parameters on
  `attest` and `confirmAdditionalAccount` keep it because their job is to name the
  subject being attested to, not the act of hashing that produced it.

  The named return value on every function that derives one is `bindingHash`
  rather than `computedHash`, in all forty-six places. Once the deriving helper is
  `_bindingHash`, naming the result for the fact that it was computed says nothing;
  every one of those returns is a binding hash. Named returns are not part of any
  selector, so nothing in the ABI signature moves and no executable byte changes,
  verified rather than assumed. They do appear as output names in the ABI JSON,
  where `computedHash` becomes `bindingHash`; nothing in this repository reads
  them, but a downstream generator that binds by output name would see it.

  The `bytes32 cfid` parameter on `attest` and `confirmAdditionalAccount` is now
  `bytes32 ubi`, and the indexed `registrationHash` field on the counterfactual and
  `WalletUBISet` events is now `ubi`. Neither costs anything: parameter
  names are in no selector and no event `topic0`, so **every event topic is
  unchanged** and the total selector count stays 53.

  **Not renamed, deliberately.** The pre-ERC-7930 scheme every live proxy still
  computes is a genuinely different value, not a UBI, so it keeps the words
  registration hash wherever it is described, here and in the fixture. Superseded
  fixture tables keep the terminology of the scheme they document, because renaming
  them would misdescribe history rather than clarify it.

- **`ACCOUNT` bindings accept a delegate.xyz route.** Authority under `ACCOUNT`
  was exactly `msg.sender == boundAddress`; it is now that, or a hot wallet
  holding a wallet-wide delegation from the bound address. The `0.0.16` entry
  below recorded the opposite rule, which was correct at that version.

  **The API is `checkDelegateForAll(account, boundAddress, DELEGATE_RIGHTS)`,
  not `checkDelegateForContract`.** delegate.xyz v2 grants come in three shapes:
  ALL delegates everything a vault holds, CONTRACT delegates what it holds inside
  one contract, and the token-scoped forms delegate a single asset. An `ACCOUNT`
  binding names an address acting as itself rather than assets it holds anywhere,
  so only the ALL shape expresses the grant. Passing `boundAddress` as both
  delegator and `contract_` to `checkDelegateForContract` asks whether the hot
  wallet may manage the bound address's holdings inside the contract at that same
  address, which is a category error for an externally owned account and the wrong
  question for a contract. It would also have silently accepted a CONTRACT-scoped
  grant naming the bound address, which is a different and narrower authorization
  than the account intended, so the check is not merely imprecise but wider than
  the grant.

  A contract-scoped or token-scoped delegation naming the bound address therefore
  confers nothing, and there is a test for each shape. Delegated authority is read
  live on every call, so revocation ends it inside the same transaction, and the
  check fails closed to the bound address alone when the registry has no code on
  the chain.

  **The revocability objection was considered and accepted, not overlooked.**
  `0.0.16` excluded `ACCOUNT` partly on the ground that an address delegating on its
  own behalf cannot revoke without the same executor it used to delegate. That
  holds: a bound contract that delegates and later loses the ability to transact
  leaves its delegate as a permanent controller, and the revocation test only covers
  a grantor that can still transact. Under the old rule that same contract froze its
  identity outright, so the trade is a surviving controller against a dead one. Do
  not re-raise this as a defect.

  **`_controlsAccount` deliberately does not get the same treatment.** It gates
  `setWalletUBIFor` and `clearWalletUBIFor`, which is a different question:
  `_hasBindingControl` asks who may manage the identity bound to an address, while
  `_controlsAccount` asks who may make an assertion on that address's own behalf
  about which identity speaks for it. Its existing routes, `owner()`, `getOwner()`
  and `DEFAULT_ADMIN_ROLE`, exist because a contract account cannot conveniently
  call itself; an externally owned account always can. Adding a delegation route
  there would let a hot wallet author a self-assertion the account never made, and
  the wallet-pointer surface is emit-only, so the authority check is the only thing
  making that log trustworthy. The asymmetry is also not new: `CONTRACT_ADMIN` has
  no delegation route in `_hasBindingControl` yet is accepted by `_controlsAccount`.

  Nothing is lost by the omission. A delegate that manages an `ACCOUNT` identity
  calls `counterfactualSetAgentWalletAndUBI`, which names the caller as the wallet,
  so the delegate designates itself and the loop still closes without anyone
  asserting on the account's behalf.

  No storage layout change: slots, offsets, labels and types are identical before
  and after. Runtime size 16,985 to 17,146 bytes, up 161, margin 7,591 to 7,430.

- **`IERCAgentBindings` is renamed `IERC8217`**, and
  `src/interfaces/IERCAgentBindings.sol` moves to `src/interfaces/IERC8217.sol`.
  The type qualifiers move with it, so `IERCAgentBindings.Standard` is now
  `IERC8217.Standard` and `IERCAgentBindings.Binding` is `IERC8217.Binding`.

  The name follows the OpenZeppelin convention of naming an interface for the
  standard it implements, as `IERC721`, `IERC1155` and `IERC165` do. This
  interface is ERC-8217's, so naming it for the ERC tells a reader which document
  specifies it; `IERCAgentBindings` named the subject but not the source.

  **Nothing observable changes.** Every executable byte of the runtime is
  unchanged, all 44 selectors are unchanged, and `interfaceId` derives from
  selectors rather than from the name, so ERC-165 detection would be unaffected
  even if this contract implemented it. Only the CBOR metadata hash moves, as it
  does for any source edit.

  One caveat, stated precisely because the expectation going in was that the ABI
  would be byte-identical and it is not. The interface name appears 23 times in
  the emitted ABI JSON, in `internalType` hints such as
  `enum IERC8217.Standard`. Those are Solidity source annotations rather than
  part of the canonical ABI: strip them and the two ABIs are identical, so every
  `type`, every function name, every selector and every encoding is unchanged. A
  consumer that keys on `internalType` strings would see the rename; nothing that
  encodes or dispatches a call would.

  **Only this interface is renamed.** `IERC8004AdapterCounterfactual`,
  `IERC8004AdapterAttestation`, `IERC8004AdapterRegistration`,
  `IERC8004IdentityRecord` and `IInteroperableAddressView` are adapter surfaces
  rather than standards, and `IERC8004IdentityRegistry` belongs to ERC-8004 and is
  already named for it. If the counterfactual surface later gets its own ERC
  number it earns the same treatment then, as a deliberate change rather than a
  side effect of this one.

- **The wallet counterfactual id surface is the wallet UBI surface.** A wallet
  counterfactual id was always the UBI of that wallet, so the whole family is
  renamed onto the vocabulary the previous entry settled. Nine ABI members move:

  | Before | After | Selector / `topic0` |
  |---|---|---|
  | `setWalletCounterfactualID(uint8,address,uint256)` | `setWalletUBI(uint8,address,uint256)` | `0x2a0f6858` → `0x4eb8a836` |
  | `setWalletCounterfactualIDFor(address,uint8,address,uint256)` | `setWalletUBIFor(address,uint8,address,uint256)` | `0x331688ed` → `0x89218f65` |
  | `clearWalletCounterfactualID()` | `clearWalletUBI()` | `0x511ac302` → `0xa306e20c` |
  | `clearWalletCounterfactualIDFor(address)` | `clearWalletUBIFor(address)` | `0x4d5d9426` → `0x19bfd9e1` |
  | `walletCounterfactualIDOf(address)` | `walletUBIOf(address)` | `0x84d1fbec` → `0x8b2d6afc` |
  | `WALLET_COUNTERFACTUAL_ID_UNSET()` | `WALLET_UBI_UNSET()` | `0x24767def` → `0x56473a07` |
  | `counterfactualSetAgentWalletAndID(uint8,address,uint256)` | `counterfactualSetAgentWalletAndUBI(uint8,address,uint256)` | `0x134d6bc9` → `0x74dc764c` |
  | `WalletCounterfactualIDReserved(bytes32)` | `WalletUBIReserved(bytes32)` | `0x11155f3a` → `0x42c8e6e4` |
  | `WalletCounterfactualIDSet(...)` | `WalletUBISet(...)` | `0xc53d8090…1b56a761` → `0x4daa9328…76a275fe` |
  | `WalletCounterfactualIDCleared(address,address)` | `WalletUBICleared(address,address)` | `0x0db92d26…a0cfbf28` → `0xd35b287e…0f3d85f9` |

  The interface file moved with `git mv` from
  `IERC8004AdapterWalletCounterfactualID.sol` to `IERC8004AdapterWalletUBI.sol` so
  history follows, and the internal helpers and the slot-3 storage variable
  followed the same naming.

  **`setAgentWalletAndID` keeps its name, deliberately.** Both combined setters
  used to end in `AndID` while meaning different types, a `uint256` agent id on
  one and a `bytes32` UBI on the other. That collision is what made the suffix
  ambiguous, and renaming one half removes it: with `AndUBI` in place there is no
  longer a second `AndID` meaning something else, so the suffix now tells a reader
  which kind of identifier the call sets. `setAgentWalletAndAgentID` would add a
  stutter for no remaining gain. The distinction is recorded on the function
  itself rather than only here.

  **What this makes visible.** A wallet can designate either identifier, and the
  choice is the difference between them: `walletAgentIDOf` returns a `uint256`
  that means something only inside the registry that issued it and on the chain
  hosting that registry, while `walletUBIOf` returns a `bytes32` that means the
  same thing everywhere, because the UBI carries its own chain and adapter in its
  preimage. That symmetry was always in the code and was invisible while the two
  halves were named on different principles. It is now stated on
  `IERC8004AdapterWalletUBI`.

### Removed

- **The wallet-to-agent-id surface is removed entirely.** Seven selectors no longer
  resolve:

  | Removed | Selector |
  |---|---|
  | `setWalletAgentID(uint256)` | `0x31b159ee` |
  | `setWalletAgentIDFor(address,uint256)` | `0xe300b9a0` |
  | `clearWalletAgentID()` | `0xa6fceb35` |
  | `clearWalletAgentIDFor(address)` | `0xa842f7aa` |
  | `walletAgentIDOf(address)` | `0x09ff1fe7` |
  | `WALLET_AGENT_ID_UNSET()` | `0x9ed22b72` |
  | `setAgentWalletAndID(uint256,address,uint256,bytes)` | `0x0f1634ba` |

  With them go `WalletAgentIDSet` (`topic0`
  `0x70d36868df65670ea06b1ef23a29c0ce0f22bd9f72162e582b34dff6d4657909`),
  `WalletAgentIDCleared` (`0xe9b93ba406d75909709010ebba159de75466fbd89235c2815e9b020f44822b53`),
  the `WalletAgentIDReserved(uint256)` error (`0x93af1327`), the `_walletAgentID`
  mapping, both internal setters and `IERC8004AdapterWalletAgentID.sol`.

  `setAgentWalletAndID` was not on the removal list but had to go with it. Its only
  distinguishing step was writing the reverse pointer; strip that and it is exactly
  `setAgentWallet`, so keeping it would have shipped a duplicate entry point under a
  name promising something it no longer did.

  **Why, so a future reader does not re-add it.** ERC-8217 argues that an agent id
  is meaningful only inside the registry that issued it and is therefore not a
  universal identifier. A reverse-resolution surface keyed on agent ids contradicts
  that in code, so the contract and the standard were saying opposite things.
  Nothing reconciled the two surfaces either: a wallet could set both to point at
  unrelated things and no rule said which a consumer should believe. The agent-id
  designation was also the less checkable of the two, since `walletAgentIDOf`
  returned a bare number that no consumer could verify without already knowing the
  registry, while the adapter itself had verified nothing.

  **What is genuinely lost** is a wallet designating an ERC-8004 agent never bound
  through this adapter. That is out of scope: the adapter can say nothing about such
  an agent, and `_setWalletAgentID` validated nothing beyond the all-ones sentinel.

  **Both wallet mappings are gone and the layout collapses to two slots.**
  `_walletAgentID` occupied slot 2 and `_walletUBI` slot 3; neither remains,
  because the reverse designation became emit-only in the same change, recorded
  below. Regular storage is now slot 0 reserved and `_bindings` at slot 1,
  confirmed with `forge inspect` against a real build rather than reasoned about.

  **The rule, so the next removal applies it correctly: reserve a slot that holds
  live data, and do not reserve one that was merely declared in a build nobody
  deployed.** Slot 0 is reserved because all three live proxies physically hold the
  old registry address in it, and sliding `_bindings` onto that word would read
  every existing binding against a dead value. Slot 2 has never held anything: the
  deployed Mainnet/Base and Sepolia implementations declare only `identityRegistry`
  and `_bindings`, and both wallet mappings existed solely in this undeployed build.
  A placeholder over either would be permanent dead space defending against nothing.
  The same rule already applied to `_primaryAgentNonces` at slot 4, removed earlier
  in this version without reservation for the same reason.

- **The wallet-to-UBI reverse designation is emit-only.** `_walletUBI`,
  `walletUBIOf`, `WALLET_UBI_UNSET` and the `WalletUBIReserved` error are all
  removed. `setWalletUBI` and `setWalletUBIFor` keep their authority checks and
  their coordinate validation and emit `WalletUBISet`; `clearWalletUBI` and
  `clearWalletUBIFor` emit `WalletUBICleared`. Nothing is stored.

  **Why it costs nothing.** The mapping was read by exactly one thing, its own
  getter. No internal path consumed it, which is precisely the condition under which
  the attestation surface chose emit-only, so this is the same rule applied
  consistently rather than a new one. The contract's job here is to verify that
  `msg.sender` holds the authority to designate and then record that fact; the
  identifier needs no storage because it is derived from coordinates, so only the
  designation is a choice, and a choice lives in a log as well as in a slot. What
  makes the log trustworthy is the authority check, not the storage.

  The complement encoding disappears with the storage, and nothing else used it. It
  existed only so an unwritten slot could be told apart from a real value, which is
  not a question that arises when there is no slot.

  **Projection rules, matching the attestation surface's wording.** Applied in log
  order, per account: the latest `WalletUBISet` wins and `WalletUBICleared` unsets,
  where latest means highest block number then highest log index. A clear from a
  different authorized party than the one that set **is** honoured, because both
  functions authorize against the account rather than against whoever wrote last, so
  the account itself, its `owner()` or `getOwner()`, and any `DEFAULT_ADMIN_ROLE`
  holder may each undo any other. An account with no `WalletUBISet` after its last
  `WalletUBICleared`, or with none at all, has no designation.

  **Gas.** A first-time designation drops from 42,988 to 20,816, a saving of 22,172,
  which is one cold `SSTORE` from zero almost exactly. Overwriting drops 172 and
  clearing 191. Emit-only is verified the same way the attestation surface verifies
  it, with `vm.record` and `vm.accesses` asserting zero writes, including once
  against a live-baseline proxy.

- **`IERC8004AdapterWalletUBI.sol` is folded into `IERC8004AdapterCounterfactual`**
  and deleted. The division that matters is derivable-from-coordinates against
  requires-an-actual-registration, and the wallet-to-UBI surface sits on the
  derivable side. Counterfactual here does not mean hypothetical, it means
  determined in advance: all four inputs exist, so the UBI exists, and performing
  the binding neither creates nor changes it, exactly as a CREATE2 address is known
  before deployment. No selector or `topic0` moves; the declarations changed file
  only.

- **`setIdentityRegistry` is gone, and `identityRegistry` is now `immutable`.**
  The registry is fixed when an implementation is constructed and can never
  change afterwards. It comes out of `initialize`, whose signature is now
  `initialize(address initialOwner)`, and the zero-address rejection moves to
  the constructor, which is strictly earlier: an implementation carrying a zero
  registry cannot be deployed at all. The `IdentityRegistryUpdated` event is
  removed with the setter, and `setIdentityRegistry(address)` no longer resolves.

  **Why: audit finding G2-01, binding capture through registry repointing.** Agent
  ids are only meaningful inside the registry that issued them. Repointing the
  adapter at a different registry made previously issued ids resolve to different
  agents, and `security-adapter` demonstrated actual capture of another user's
  agent with two working proofs of concept. One needed no hostile registry at
  all: a normal fresh registry restarts its id sequence, so ordinary
  registrations afterwards overwrite the first agents' bindings at the
  unconditional `_bindings` write. Removing the capability eliminates that at the
  root rather than guarding the write.

  **A future maintainer must not undo this reasoning.** The `_bindings[agentId]`
  write is still unconditional, with no check that the id is unused. That is safe
  only because the registry can never change, so the registry's own id sequence
  never restarts and never reissues an id the adapter has already bound.
  Reintroducing any way to repoint the registry, including an upgrade that swaps
  it, reopens G2-01 immediately. If the write is ever wanted on a mutable
  registry, it needs its own collision guard first.

  **`_authorizeUpgrade` now enforces the same property across upgrades**, refusing
  any implementation whose `identityRegistry()` differs from this one, with a new
  `RegistryMismatch` error. This works because of the immutability rather than in
  spite of it. `upgradeToAndCall` executes against the CURRENT implementation, so
  the outgoing one calls `_authorizeUpgrade(newImplementation)` before the switch
  and can read the incoming implementation directly. An immutable is compiled into
  each implementation's own runtime code, so that read returns the incoming
  implementation's baked value. A storage variable would return that
  implementation's own slot 0, which is zero and never initialized, so the check
  would be unwritable.

  **The storage consequence, which is the risky part.** `identityRegistry`
  occupied slot 0 on all three live proxies, each with a real address written.
  Making it immutable frees the slot but not the bytes, so a `uint256 private
  __deadRegistrySlot` placeholder now holds slot 0 down and **slot 0 must never be
  reused.** Without the placeholder every mapping slides down one slot and
  `_bindings` lands on top of the old registry address, which was verified with
  `forge inspect` rather than reasoned about. Regular storage now runs from slot 1
  to slot 3.

  **Deploy scripts carry a second layer for the bootstrap hop.** The on-chain check
  lives in the outgoing implementation, and the implementation currently deployed
  is the storage-based one with no such check, so the first hop is unguarded on
  chain by design. `DeployAdapterImplementation.s.sol` therefore reads the live
  proxy's `identityRegistry()`, requires the configured value to match it, and
  requires the freshly constructed implementation to report it back, refusing to
  proceed otherwise. Every hop after the first is guarded by the contract.

- **`cf-registration` is no longer a reserved metadata key**, and its
  `CF_REGISTRATION_KEY()` getter is gone with it, so that selector no longer
  resolves. `agent-binding` stays reserved and its behaviour is unchanged.

  `agent-binding` is reserved because the adapter writes it, so an unreserved key
  would let a caller forge a record the adapter itself authors. `cf-registration`
  was written by no path, so there was no authoritative record to forge and the
  reservation protected a name rather than data. A name is not defensible: a
  caller out to mislead an indexer can write `cfid`, `counterfactual-id` or any
  other suggestive spelling, so reserving exactly one gave false comfort.

  The real defence is `bindingHashOf(agentId)`, added earlier in this
  version. It derives an agent's identifier rather than storing it, so it cannot
  be spoofed, and it is the authoritative source. That also settles the earlier
  proposal to write `cf-registration` on every `register`, which was declined
  because the value is derivable and the write would have cost an external call
  and a cold `SSTORE` on the most-used function.

  Verified before removing the guard: no path in `src/` writes the key. The
  adapter makes exactly three `setMetadata` calls, one writing `agent-binding`
  and two forwarding caller-supplied keys, so removing the check cannot let a
  caller overwrite anything the contract authored. Why it is *not* reserved is
  recorded on `BINDING_METADATA_KEY`, where an editor noticing the asymmetry will
  see it, so it does not get re-added as a consistency fix.

  Removing one of the two comparisons on the metadata path is measurably cheaper:
  `setMetadata` 56,532 to 56,415, `counterfactualSetMetadata` 22,569 to 22,450,
  and roughly 145 gas per entry on both batch paths. The internal helper is
  renamed `_requireNoReservedBindingKey`, since it now guards one key.

### Removed

- **The signed primary-agent surface.** `setPrimaryAgentWithSig`,
  `clearPrimaryAgentWithSig` and `primaryAgentNonces` are gone, along with the
  `PrimaryAgentSetWithSig` and `PrimaryAgentClearedWithSig` events, the adapter's
  EIP-712 domain and typehashes, the 30-minute deadline bound, and the
  `SignatureExpired`, `SignatureDeadlineTooFar` and `InvalidSignature` errors. The
  `MessageHashUtils` and `SignatureChecker` imports went with them, since nothing
  else used either.

  What it offered was relayed, gasless setting of another account's primary agent
  from that account's own signature. `setWalletAgentIDFor` already covers the
  acting-for-an-account case, with the controller calling directly and paying gas,
  so what is lost is the relayer path alone. Adding it back later is append-only.
  `setWalletAgentID`, `setWalletAgentIDFor`, `clearWalletAgentID`,
  `clearWalletAgentIDFor`, `walletAgentIDOf` and the whole counterfactual primary
  surface are untouched.

  **Storage now ends at slot 3.** `_primaryAgentNonces` was slot 4, the last one,
  with nothing after it, so it is removed outright rather than left as a gap or a
  deprecated placeholder. That is safe because it was never written on any chain:
  verified on 2026-08-19 by calling `primaryAgentNonces(address)` on all three live
  proxies, where it reverts because no live implementation exposes it, and by
  reading raw slot 4 on each, which is zero. The storage header, the
  upgrade-validation tests and
  [`docs/fixtures/adapter-v014-storage-layout.md`](./docs/fixtures/adapter-v014-storage-layout.md)
  move with it, and a test asserts nothing writes past slot 3.

  Two tests assert the removal is complete rather than merely compiling: one probes
  each removed selector and requires it not to resolve, the other requires neither
  `WithSig` event topic to appear on the surviving set and clear paths.
  [`docs/fixtures/adapter-primaryagent-withsig.md`](./docs/fixtures/adapter-primaryagent-withsig.md)
  is kept as the design record, marked removed.

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

- **No target validation.** A nonzero `ubi` that matches no claim passes on
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

Measured in the assembled contract, per live chain, because the ERC-7930 encoder's
cost depends on the chain reference length:

| Function | Ethereum | Base | Sepolia |
| --- | ---: | ---: | ---: |
| `attest`, small payload | 7,581 | 7,581 | 7,581 |
| `confirmAdditionalAccount` | 6,916 | 6,916 | 6,916 |
| `bindingHashFor` | 5,749 | 5,749 | 5,749 |
| `revoke` | 1,889 | 1,889 | 1,889 |

Flat across chains, which is itself the effect of the OpenZeppelin adoption: its
branchless length computation does not vary with the reference, where the former
in-house loop cost about 105 gas per reference byte.

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

- **The ERC-7930 encoder is now OpenZeppelin's `InteroperableAddress`.**
  `_erc7930AddressFor` became a thin wrapper delegating to `formatEvmV1`, and the
  in-house body went away with it. `_interoperableAddress` stays
  `internal view virtual` and the internal API is unchanged.

  **No identity re-keys.** That is the gate this change had to pass, and it did:
  every published fixture vector — the counterfactual hashes, the attestation
  identifiers, and the ERC-7930 spec examples — passes completely unchanged, with
  no fixture document edited. The encoding is byte-identical; only the code that
  produces it moved.

  Both former encoders are frozen in `test/Adapter8004.erc7930.t.sol` as
  `ReferenceErc7930` (byte-at-a-time) and `WordAlignedErc7930`. The roles inverted
  rather than disappeared: OpenZeppelin used to be the independent oracle for our
  encoder, and our encoders are now the independent oracles for OpenZeppelin's.
  Three implementations, all agreeing, is the safety argument. Do not delete them.

  **The dependency is load-bearing in a way an ordinary one is not.** The library's
  file is `draft-` prefixed, so OpenZeppelin owes no encoding stability across
  releases, and a submodule bump that changed the output would silently re-key
  every identity this contract has ever issued — no revert, nothing visibly wrong.
  `test/Adapter8004.erc7930-frozen.t.sol` exists to make that loud: 26 tests
  pinning exact bytes for twelve chain ids on both shapes, three-way agreement
  across all 32 reference lengths, round trips through `parseEvmV1`, and the
  published identities asserted end to end through `bindingHashFor`, the
  attestation identifier and a real counterfactual emission. One test,
  `testOpenZeppelinEncodingIsFrozen`, exists solely to fail on an upstream
  encoding change and says in its own comment that editing it is never the fix.

  **The submodule is pinned to the `v5.6.1` release tag**, commit `5fd1781b`,
  rather than to `9cfdccd3`, an untagged development commit from 2026-03-27 that
  sat 1,146 commits past `v4.8.0`. Unreleased upstream code has no business
  sitting under every identity this contract issues, and the CSO graded that a
  ceremony blocker.

  The bump changes no encoding, which was verified rather than assumed.
  `contracts/utils/draft-InteroperableAddress.sol` is byte-identical across the
  two commits: the same git blob `10b4e426`, the same SHA-256, the same 10,788
  bytes. Its one differing dependency, `Bytes.sol`, differs only in the line
  wrapping of `reverseBytes16`, which the encoder never calls. Every published
  fixture vector then passed unchanged, checked against both fixture documents
  and against values derived from the contract itself: the three chain
  Interoperable Addresses, the four counterfactual hashes, the four per-standard
  hashes, and all five attestation identifiers. Not one moved, and no fixture
  document was edited.

  **Expect a different `EXTCODEHASH` anyway, and do not read it as a different
  contract.** Solidity appends a CBOR metadata trailer whose IPFS hash covers the
  source paths and compiler settings, so it moves when the import resolves
  through a different submodule commit even with identical source. Measured: the
  runtime is 18,112 bytes on both pins and the first 18,059 bytes, meaning all of
  the executable code, are byte-identical; only the 51-byte trailer differs. The
  runtime code hash goes from `0x40612f2d…b49c88b6` to `0xfe6119b9…e6d0f70d`.
  The solc version marker in the trailer is `0.8.30` on both.

  **Correction to the gas rationale.** This change was taken on a measurement that
  did not survive being made again in the assembled contract. Benchmarked in
  isolation, OpenZeppelin was cheaper than the word-aligned encoder by 21 gas on
  Ethereum, 126 on Base and 231 on Sepolia. Measured through the real contract it
  is the other way round on two of the three live chains:

  | Chain | word-aligned | OpenZeppelin | Δ |
  | --- | ---: | ---: | ---: |
  | Ethereum (L=1) | 5,602 | 5,749 | **+147** |
  | Base (L=2) | 5,707 | 5,749 | **+42** |
  | Sepolia (L=3) | 5,812 | 5,749 | −63 |

  Same shape for `attest` and `confirmAdditionalAccount`, within a few gas. The
  in-isolation figures were measured in a tiny benchmark contract where the
  optimizer had far more inlining freedom than it has inside a 19KB contract at
  `optimizer_runs = 200`. So on the two chains that carry production this costs
  roughly 40 to 150 gas rather than saving it. What the change does buy, and what
  survives the correction: one fewer hand-written encoder to keep correct, and the
  removal of the fallback path, which cost 11,291 gas at a seven-byte reference
  against OpenZeppelin's flat 1,295, with a 9,459-gas cliff at the handoff.

- **`_erc7930AddressFor` was word-aligned** before the above superseded it. The
  ERC-7930 envelope was built
  with a single `MSTORE` for every case that fits in a 32-byte word, instead of up
  to twenty-six bounds-checked byte writes. The byte-at-a-time loop is kept as the
  fallback for chain ids too large to fit, so the encoder stays total.

  `length <= 32` is the exact condition for both shapes at once: with an address
  the envelope is `26 + L` bytes, so the fast path covers `L <= 6`, meaning chain
  ids below 2^48; without one it is `6 + L`, covering `L <= 26`. Every chain in
  existence is far inside both.

  **Every identity this contract derives comes through this helper** — every
  UBI, every `attestationId`, and the EIP-712
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
  | `bindingHashFor` | 9,647 | 2,645 | −7,002 |
  | `revoke` | 1,889 | 1,889 | 0 |

  Exactly one derivation's worth in each case.

  These four figures are gas-report numbers taken on the local test chain and are
  not comparable to the per-chain table in the Gas section above, which was
  measured in the assembled contract at each live chain id. They are kept because
  the *difference* is what this entry is about, and both columns share one basis.
  The absolute numbers of record are the ones in the Gas section.

  **That framing was misleading and is corrected here.** "Recovers 85–88% of the
  build" invited the reading that the rewrite put this contract ahead of the
  ecosystem reference. It did not. Those savings were measured against this
  contract's own previous encoder, which was roughly six times more expensive than
  OpenZeppelin's throughout; the rewrite closed that gap to near parity and, as the
  in-contract numbers above show, left it slightly behind on Ethereum and Base. The
  honest summary of the word-align is that it took this contract from about six
  times worse than the reference implementation to roughly level with it.

  The alternatives were priced and rejected: caching the chain-dependent prefix in an `immutable` recovers only
  about 3,300 of that, because the expensive half is the twenty address bytes and
  `address(this)` in a constructor is the implementation rather than the proxy; a
  storage cache is the only mechanism that can capture the proxy address, and it
  wins about 700 gas warm while losing about 1,400 on the cold first touch that
  most transactions actually pay, in exchange for a storage slot. This option
  changes no deployment property at all.

- **The counterfactual identity gains the token standard.** The
  UBI preimage becomes four components:

  ```
  keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))
  ```

  `standard` is the `Standard` enum as its `uint8`, sitting between the
  adapter's ERC-7930 Interoperable Address and `boundAddress`. Always
  `abi.encode`, never packed. The reserved `extraData` discriminator that also
  stood in this preimage earlier in the version was removed, recorded below.

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

- **`Standard` numbering is now identity-critical.** The enum's `uint8` is in
  the preimage, so renumbering a member re-keys every counterfactual identity
  claimed under it, along with every attestation and reverse pointer naming one.
  Before this version the numbering was event-critical, which tolerated
  renumbering with a re-index. It no longer does. **Append only: never renumber,
  never reorder, never remove a member.** The constraint is recorded on the enum
  in [`IERC8217.sol`](./src/interfaces/IERC8217.sol).

- **`registrationHash(address,uint256)` is removed and replaced by the
  coordinate-form view that is now called `bindingHashFor(Standard,address,uint256)`.**
  It carried the name `registrationHash` for most of this version and was renamed
  with the rest of the terminology, recorded below. The old selector is gone rather
  than kept as an overload, deliberately: a stale caller reverts cleanly instead of
  silently computing a hash that no longer identifies anything.

- **`setWalletUBI` and `setWalletUBIFor` each
  gain a `Standard` parameter**, immediately before `boundAddress`. Both old
  selectors are gone, for the same reason. `clearWalletUBI[For]`
  and `walletUBIOf` are unchanged.

- **The five counterfactual update events and `WalletUBISet` gain
  a non-indexed `standard`**, as their first non-indexed field:
  `CounterfactualAgentURISet`, `CounterfactualMetadataSet`,
  `CounterfactualMetadataBatchSet`, `CounterfactualAgentWalletSet`,
  `CounterfactualAgentWalletUnset`. This makes a log line verifiable on its own: a
  reader recomputes the UBI the event names from the event's own
  fields, with no lookup of the claim that created the identity.
  `CounterfactualAgentRegistered` already carried the standard. Every
  counterfactual `topic0` moves in this version, so indexers resubscribe to all
  seven; the current values are tabulated in
  [`adapter-counterfactual-hashes.md`](./docs/fixtures/adapter-counterfactual-hashes.md).

- **The reserved `extraData` discriminator is removed**, from the
  UBI preimage and from every counterfactual event. The preimage
  loses its trailing `bytes32` and seven events lose their `bytes32 extraData`
  field, so every counterfactual hash and every counterfactual `topic0` moves
  again within this version. The seven are the six on
  `IERC8004AdapterCounterfactual`, `CounterfactualMetadataBatchSet` included,
  plus the event this version renamed to `WalletUBISet`. Earlier
  revisions of this entry said eight, which counted emit sites rather than
  events, since `WalletUBISet` is emitted from more than one
  function.

  **Why.** The field preserved no optionality. It was a compile-time constant no
  caller could reach, so every on-chain path derived with zero, and an identity
  under a non-zero discriminator could be attested to but never claimed or
  registered: there was no function that would emit one. Removing it makes the
  identifier correspond exactly to stored state, the adapter address plus exactly
  the `Binding`, with nothing in the preimage that `bindingOf` cannot return. It
  also takes 32 bytes off every counterfactual log line and one word out of every
  hash.

  **Cost on chain: none**, for the same reason the standard's insertion was free.
  No proxy ever ran a preimage containing `extraData`; every live proxy still runs
  the pre-ERC-7930 scheme, so this rides the `0.0.14` cutover rather than adding
  one. The two superseded `extraData` schemes are retained under their own headings
  in the hash fixture so a reimplementer can tell which formula their output
  matches.

### Unchanged, deliberately

- **The `Binding` struct is untouched.** With `extraData` gone, the identity
  preimage is now exactly the adapter address plus the three fields the struct
  already holds, so there is nothing left to add to it.
- **Storage is untouched by the identifier change.** No slot is added, reserved
  or repurposed by it, and the upgrade still takes empty `upgradeToAndCall` data.
  The layout ends at slot 3 once the signed primary-agent surface is removed,
  recorded under Removed above.
- **`bindingOf` keeps its signature and return encoding**, and `AgentBound` keeps
  its shape and `topic0`.
- **`register` gains no parameter.** It already takes the standard.

### Size

`forge build --sizes` on this implementation:

| Contract | Runtime (B) | Initcode (B) | Runtime margin (B) |
| --- | ---: | ---: | ---: |
| `Adapter8004` | 17,808 | 18,093 | 6,768 |

Against the 24,576-byte cap, built up from `0.0.16`:

| Step | Runtime (B) | Margin (B) |
| --- | ---: | ---: |
| `0.0.16` | 18,400 | 6,176 |
| + the standard in the counterfactual identifier | 18,660 | 5,916 |
| + the attestation surface | 19,707 | 4,869 |
| − the five type-constant readers, replaced by the enum | 19,365 | 5,211 |
| + the word-aligned ERC-7930 encoder | 19,492 | 5,084 |
| − the in-house encoder, + OpenZeppelin's | 19,449 | 5,127 |
| − the signed primary-agent surface | 17,688 | 6,888 |
| + the two combined wallet-id setters | 18,123 | 6,453 |
| + the hash return on the combined setter | 18,125 | 6,451 |
| + the hash return on the five updaters | 18,152 | 6,424 |
| + `bindingHashOf`, − a duplicated unknown-agent check | 18,146 | 6,430 |
| − the `cf-registration` reservation | 17,808 | 6,768 |

The attestation surface cost 1,047 bytes, under the 1,500–2,200 it was estimated
at, and the enum handed 342 of them back by deleting five public getters. Removing
the signed primary-agent surface gave back 1,761, far more than its three
functions suggest, because the ECDSA and ERC-1271 verification machinery went with
them. The encoder rewrite cost 127, and handing the encoding to OpenZeppelin gave 43 back —
the library's `Math`, `SafeCast` and `Bytes` dependencies did not bloat the
artifact, because only the reached paths survive dead-code elimination and the
removed in-house body more than paid for them. Margin is 5,127 bytes, comfortably
clear of the 2,000 floor. The word-align rewrite was predicted to land neutral or
smaller, on the
reasoning that replacing the byte loops in place would delete more than the fast
path adds; it did not, because the fallback keeps those loops and the fast path's
shift arithmetic is added on top. It came in well under the +267 upper bound the
investigation gave, but it is a cost, not a saving. A test fails the suite if the margin ever falls below 2,000 bytes; if it
does, the fix is the extraction the upgrade docs describe, not a lower floor.
Extraction would re-key every attestation identifier, because the identifier
binds the emitting address, so it is a one-way door. Dropping the `cf-registration` reservation gave back 338: two public
constants, their getter, and one of the two comparisons on every metadata write.

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
  between two transactions. `register` and `setWalletAgentID` remain available
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
  `CounterfactualAgentWalletUnset`) and on `WalletUBISet`, so
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
    `setWalletAgentIDFor` has always accepted a `DEFAULT_ADMIN_ROLE` holder, so before this an admin
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
  primary uses `register`, mints, then calls `setWalletAgentIDFor(buyer, agentId)`; otherwise the buyer
  sets it separately with `setWalletAgentID`.
- Split reverse resolution into two independent systems:
  - full ERC-8004: `uint256` `setWalletAgentID`, `walletAgentIDOf`, full-only events, and
    `primaryAgentNonces`;
  - counterfactual: new `set/clear/primaryCounterfactualAgent...` APIs, coordinate-bearing
    `PrimaryCounterfactualAgent...` events.
- Removed the ambiguous `nonces(address)` API and old `setWalletAgentID(bytes32)` selector.
  `WalletAgentIDSet` and `PrimaryAgentSetWithSig` now index a `uint256`, changing their topic0.
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

- Appended `_walletAgentID` (slot 2), `_walletUBI` (slot 3), and
  `_primaryAgentNonces` (slot 4) directly after the live fields. Slot 4 was
  removed again at `0.0.17`, so the shipped layout ends at slot 3. The unreleased
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
  agent, in one transaction. Equivalent to calling `register(...)` then `setWalletAgentID(bytes32(agentId))`
  yourself: identical token-control authorization, `AgentBound` event, and returned id, plus a
  standard `WalletAgentIDSet(caller, bytes32(agentId), caller)`. No new storage, authorization, or event
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
- **Signed (account-self) primary-agent surface** (`IERC8004AdapterWalletAgentID`):
  - `setPrimaryAgentWithSig(address account, bytes32 agentId, uint256 deadline, bytes signature)`
    and `clearPrimaryAgentWithSig(address account, uint256 deadline, bytes signature)` — any
    relayer submits a signature by `account` itself (EOA `ecrecover` or the account's ERC-1271
    policy, via `SignatureChecker`). Strictly account-self: there is **no** owner/admin/controller
    signature route (that authority stays on the paid `setWalletAgentIDFor` / `clearWalletAgentIDFor`).
  - `nonces(address)` — one monotonic nonce per account, **shared** by signed set/clear operations,
    embedded in the signed struct (not a calldata argument) and consumed once per success, so a used
    signature cannot be replayed and any op pre-signed against the same nonce is invalidated.
  - `MAX_PRIMARY_AGENT_SIGNATURE_LIFETIME = 30 minutes` deadline cap (a deadline equal to the current
    block timestamp is still valid); errors `SignatureDeadlineTooFar` / `SignatureExpired` and
    `InvalidSignature`.
  - Audit events `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)` and
    `PrimaryAgentClearedWithSig(account, relayer, nonce)`. The legacy `WalletAgentIDSet` /
    `WalletAgentIDCleared` events are unchanged and still emitted first with `setBy` / `clearedBy` =
    `msg.sender` (the relayer); indexers act on the legacy event and use the signed event only for
    provenance (authorization = EIP-712, relayer, nonce).
  - `agent-binding` semantics unchanged: `agentId == 0` is a valid claim; the all-ones sentinel is
    reserved and reverts `WalletAgentIDReserved`. The paid setters and slot-2 complement encoding
    are untouched.
  - Consumer fixtures (EIP-712 type strings, viem typed-data, and example calldata) published under
    [`docs/fixtures/`](./docs/fixtures/adapter-primaryagent-withsig.md).

## [0.0.10] - Unreleased

Source version. Not deployed. Supersedes the `0.0.9` primary-agent semantics
below (neither `0.0.9` nor `0.0.10` is live on any chain).

### Changed
- **Primary-agent storage is now complement-encoded** (`IERC8004AdapterWalletAgentID`).
  The `_walletAgentID` mapping still lives at slot 2 as `mapping(address => bytes32)`
  — the storage layout is byte-identical (slots 0/1/2 unchanged, verified via
  `forge inspect ... storageLayout`) — but it now stores the **bitwise complement**
  of the id (`~agentId`) rather than the raw id.
  - **Agent id `0` is now a representable primary agent.** An unwritten slot is
    zero, which complements to the all-ones sentinel, so "unwritten" reads as
    "unset" for free while every real id — `0` included — round-trips. The old
    `0.0.9` design treated `agentId == 0` as a clear, so id `0` could not be set.
  - New sentinel `WALLET_AGENT_ID_UNSET = bytes32(type(uint256).max)` (all ones).
    `walletAgentIDOf(account)` returns it when the account has never set an id or
    has cleared it (previously it returned `bytes32(0)`).
  - Setters no longer treat `0` as a clear. Removal is explicit via new
    `clearWalletAgentID()` / `clearWalletAgentIDFor(address)`, which emit a
    dedicated `WalletAgentIDCleared(account, clearedBy)` event.
  - `setWalletAgentID` / `setWalletAgentIDFor` revert `WalletAgentIDReserved`
    when passed the all-ones sentinel id (it would complement to zero and alias
    "unset").
  - `WalletAgentIDSet` is now emitted only for real-id writes; clears emit
    `WalletAgentIDCleared`. Authorization for the `*For` calls is unchanged
    (account itself, `owner()` / `getOwner()`, or `DEFAULT_ADMIN_ROLE`).

## [0.0.9] - Unreleased

Source version. Not deployed. Its primary-agent semantics are superseded by
`0.0.10` above; the description below is retained as historical record.

### Added
- **Primary-agent reverse resolution** (`IERC8004AdapterWalletAgentID`): an
  `address => bytes32 agentId` mapping on the adapter that resolves a wallet
  address (or any address recorded in agent metadata) to the agent it claims to
  belong to, on this chain. Combined with the agent's own wallet claim (ERC-8004
  `agentWallet` or the counterfactual `CounterfactualAgentWalletSet` event), a
  consumer can verify that a wallet and an agent mutually point at each other.
  - The id is an ERC-8004 registry token id (small, incremental, stored as
    `bytes32(id)`) or a 32-byte counterfactual `registrationHash`. The two id
    spaces do not collide, so a single mapping holds both.
  - `setWalletAgentID(bytes32 agentId)` sets the caller's own id;
    `setWalletAgentIDFor(address account, bytes32 agentId)` sets an account's id
    when the caller is the account, its `owner()` / `getOwner()`, or a holder of
    its `DEFAULT_ADMIN_ROLE`; `walletAgentIDOf(address)` reads it. `agentId == 0`
    clears. Emits `WalletAgentIDSet(account, agentId, setBy)`.
  - The control check is a defensive static call that tolerates non-conforming
    return data (wrong length or dirty bits) without reverting, and is
    account-scoped: a contract that misreports its controller can only affect its
    own mapping entry. New storage `_walletAgentID` is appended after `_bindings`
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
