# Implementation plan: separate primary-agent systems and ERC-7930 counterfactual hashes

**Locked release:** `0.0.14`  
**Scope:** contracts, interfaces, fixtures, tests, release/deployment documentation  
**Out of scope:** implementing this plan or changing the underlying full ERC-8004 registry

## Decision summary

The adapter will expose two independent reverse claims:

1. A **full ERC-8004 primary agent**, stored as a registry `uint256 agentId`.
2. A **counterfactual primary agent**, stored as a `bytes32 registrationHash`.

The full system keeps the short `primaryAgent...` names. The counterfactual system uses explicit
`primaryCounterfactualAgent...` names. Each system gets its own mapping, events, and direct/paid
writes. Only the full system gets signed writes, EIP-712 types, and a nonce stream.
`registerAndSetPrimary` writes only the full mapping; counterfactual primary setters write only the
counterfactual mapping.

The same `0.0.14` release also makes ERC-7930 part of the canonical counterfactual identity domain.
Every `registrationHash` replaces the bare EVM `block.chainid` and adapter address with the full
ERC-7930 v1 Interoperable Address of the adapter proxy. The token contract remains a naked EVM
`address`. On EVM, the adapter deterministically builds its `eip155` Interoperable Address from
`block.chainid` plus the proxy's raw 20-byte address; the locked hash preimage is
`abi.encode(interoperableAddress(adapter), tokenContract, tokenId)`. Chain binding comes from the
adapter Interoperable Address alone. This deliberately changes every existing counterfactual hash.
There is no legacy-hash fallback, dual emission, or later compatibility release.

The current mixed mapping and its shared nonce mapping are unreleased source surfaces: the README
and changelog say that no production proxy has deployed the primary-agent surface. Append three
fresh mappings directly after the live two-slot layout at slots 2 through 4. There is no heuristic
migration, dual read, or dual write. Accounts re-attest independently in each new system.

This is intentionally a hard ABI and EIP-712 cutover. It is safer than preserving an API whose
central meaning is ambiguous.

## Problem and invariant

Today `_primaryAgent[address]` can contain either `bytes32(agentId)` or a counterfactual
`registrationHash`. `primaryAgentOf` cannot tell consumers which system produced the value, and a
counterfactual combined registration overwrites a full primary (or vice versa). The signed paths
also serialize both kinds of writes through `nonces[address]`.

After this change, the following invariants must hold:

- `primaryAgentOf(account)` reads only the full ERC-8004 mapping and returns a `uint256 agentId`.
- `primaryCounterfactualAgentOf(account)` reads only the counterfactual mapping and returns a
  `bytes32 registrationHash`.
- No public or internal setter accepts a discriminator or routes one value into either mapping.
- A write or clear in one system cannot change the other system's value; counterfactual writes
  cannot consume the full system's signature nonce.
- Every combined registration helper has exactly one statically selected destination mapping.
- Both mappings retain explicit clear operations and distinguish a real zero value from unset.
- Every counterfactual emitter, pointer setter, and view helper derives one canonical
  hash from the adapter's full ERC-7930 Interoperable Address, naked token-contract address, and
  token id.
- The counterfactual namespace differs when the ERC-7930 `ChainType` or `ChainReference` differs,
  even if the adapter and token coordinates and numeric-looking chain reference are equal.
- Reverse claims remain account assertions, not proof of a two-way relationship. Consumers still
  verify the corresponding full `agentWallet` or counterfactual wallet event separately.

## ERC-7930 counterfactual hash domain

### Canonical bytes and EVM derivation

Use [ERC-7930](https://eips.ethereum.org/EIPS/eip-7930) v1 and the
[CAIP-350 `eip155` profile](https://namespaces.chainagnostic.org/eip155/caip350) exactly. The
general envelope is:

```text
version:uint16 || chainType:uint16 || chainReferenceLength:uint8
|| chainReference:bytes || addressLength:uint8 || address:bytes
```

All fixed-width integers in this inner envelope are big-endian. For the CAIP-350 `eip155` profile,
`version = 0x0001`, `chainType = 0x0000`, and `chainReference` is `block.chainid` encoded as the
shortest non-empty big-endian unsigned integer. Leading zero bytes are forbidden. The implementation
must reject a zero chain id. For `interoperableAddress(account)`, `addressLength = 20` and `address`
is the raw 20-byte EVM address, including all zero bytes when `account == address(0)`. For
`chainIdentifier()`, `addressLength = 0` and the address is absent. EVM chain ids from 1 through
`type(uint256).max` therefore use a 1-to-32-byte reference, a 7-to-38-byte Chain Identifier, and a
27-to-58-byte full Interoperable Address.

Examples:

| Network | `block.chainid` | ERC-7930 Chain Identifier |
|---|---:|---|
| Ethereum mainnet | `1` | `0x00010000010100` |
| Base mainnet | `8453` (`0x2105`) | `0x0001000002210500` |
| Ethereum Sepolia | `11155111` (`0xaa36a7`) | `0x0001000003aa36a700` |

Derive these values on demand from `block.chainid`; do not add an initializer, constructor argument,
immutable, or storage slot. An immutable would bind the implementation rather than the proxy's
execution context and a configurable value could disagree with the executing chain. Put byte
construction in reusable helpers (conceptually `_chainIdentifier()` and
`_interoperableAddress(address)`) and use the full-address helper only for the adapter hash
coordinate.

ERC-7930 and the namespace profiles are still in Review/Draft as of this plan. Pin the implemented
v1 envelope and `eip155` profile rules in NatSpec, fixtures, and tests. A later normative encoding
change is a new hash-version decision; it must not silently change `registrationHash` under an
already-deployed implementation.

### Exact hash preimage

Define the canonical hash exactly as:

```solidity
keccak256(
    abi.encode(
        interoperableAddress(address(adapter)), // bytes: chain + 20-byte proxy
        tokenContract, // naked EVM address
        tokenId
    )
)
```

Use standard `abi.encode(bytes,address,uint256)`, not `abi.encodePacked`. The dynamic adapter
Interoperable Address length and normal ABI offset/padding are part of the preimage. Do not encode
`tokenContract` as an Interoperable Address, do not hash the adapter Interoperable Address down to
`bytes32`, do not substitute a CAIP-2 text string, and do not separately append `block.chainid`.
The adapter Interoperable Address already carries its version, namespace (`ChainType`), reference
length, reference, address length, and address.

The token standard remains excluded, preserving the existing rule that one token coordinate has one
counterfactual identity regardless of which supported interface proves control.

### Public helpers and foreign-chain calculation

Keep the existing local canonical helper:

```solidity
function registrationHash(
    address tokenContract,
    uint256 tokenId
) external view returns (bytes32);
```

Add a read-only helper exposing the exact local envelope:

```solidity
function chainIdentifier() external view returns (bytes memory);
function interoperableAddress(address account) external view returns (bytes memory);
```

`chainIdentifier()` remains useful for chain inspection, but it is not itself a field in the
canonical hash preimage. Do **not** add a production overload that accepts a caller-supplied chain,
adapter, or hash. Such a result would not be a registration valid on the executing adapter and would
create an easy-to-misuse second notion of "canonical." Keep pure internal
`_registrationHashFor(bytes,address,uint256)` and `_interoperableAddressFor(uint256,address)`
primitives if useful for composition and testing, but every state/event path must call the local
wrapper that supplies `address(this)` and the local chain for the adapter.

### Cross-namespace vectors

Fixtures must include exact envelope bytes and final hashes. With:

```text
adapter       = 0x1111111111111111111111111111111111111111
tokenContract = 0x2222222222222222222222222222222222222222
tokenId       = 42
preimage      = abi.encode(bytes,address,uint256)
```

the required vectors are:

| Chain | Adapter Interoperable Address | Naked token contract | `registrationHash` |
|---|---|---|---|
| Ethereum mainnet | `0x000100000101141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e` |
| Base mainnet | `0x00010000022105141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xd4f7e7c3e75d4d9c011d61c33666c7ba460bcb0a5964112643a31802fbf0791f` |
| Ethereum Sepolia | `0x0001000003aa36a7141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xbd88f093e45b0adc6546b1363d8f876ac71cf52737abea2803edb5f938baeca5` |
| Solana mainnet namespace stress example | `0x000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xa992e5d61c04f1741eccdd005ea76b2584ec995dd010df8c3303afc4270614cc` |

The final row is only an adapter-chain namespace stress vector. It uses `ChainType = 0x0002` and
the Solana mainnet reference with an illustrative 20-byte adapter coordinate; it is not a native
Solana CAIP-350 address profile or execution API.

## Public API and type decisions

### Full ERC-8004 system

Keep `IERC8004AdapterPrimaryAgent`, but redefine it as full ERC-8004 only. Use `uint256` throughout
so its ABI and NatSpec describe a registry token ID rather than a generic 32-byte identifier.

```solidity
uint256 public constant PRIMARY_AGENT_UNSET = type(uint256).max;

function setPrimaryAgent(uint256 agentId) external;
function setPrimaryAgentFor(address account, uint256 agentId) external;
function clearPrimaryAgent() external;
function clearPrimaryAgentFor(address account) external;
function primaryAgentOf(address account) external view returns (uint256 agentId);

function setPrimaryAgentWithSig(
    address account,
    uint256 agentId,
    uint256 deadline,
    bytes calldata signature
) external;
function clearPrimaryAgentWithSig(
    address account,
    uint256 deadline,
    bytes calldata signature
) external;
function primaryAgentNonces(address account) external view returns (uint256);
```

`type(uint256).max` remains reserved as the full-system unset sentinel; agent ID `0` remains valid.
The full setters do not require the account to own the referenced registry NFT and do not add a
binding check. This mapping is still the account's claim. The type and dedicated API establish the
namespace; consumers establish truth through the existing two-way wallet check. The implementation
may call `identityRegistry.ownerOf` in consumer validation flows, but it should not add that external
call to pointer writes in this change.

Changing `setPrimaryAgent(bytes32)` to `setPrimaryAgent(uint256)` gives the setter a new selector.
The getter and clear selectors do not encode return types and therefore retain their selectors, but
their documented meaning becomes full-only and their implementation reads the new full mapping.
No compatibility alias should expose the legacy mixed slot.

### Counterfactual system

Add `IERC8004AdapterCounterfactualPrimaryAgent`. Name the noun consistently as "primary
counterfactual agent":

```solidity
bytes32 public constant PRIMARY_COUNTERFACTUAL_AGENT_UNSET =
    bytes32(type(uint256).max);

function setPrimaryCounterfactualAgent(
    address tokenContract,
    uint256 tokenId
) external returns (bytes32 registrationHash);
function setPrimaryCounterfactualAgentFor(
    address account,
    address tokenContract,
    uint256 tokenId
) external returns (bytes32 registrationHash);
function clearPrimaryCounterfactualAgent() external;
function clearPrimaryCounterfactualAgentFor(address account) external;
function primaryCounterfactualAgentOf(
    address account
) external view returns (bytes32 registrationHash);

```

Counterfactual setters take `tokenContract` and `tokenId`, not a caller-supplied hash. They derive
the value through the canonical `_registrationHash(tokenContract, tokenId)`. This makes it
impossible for the counterfactual API to accidentally store a full agent ID and ensures the stored
hash always uses the full local ERC-7930 Interoperable Addresses of the adapter proxy and token
contract plus the token id. It
does not require a prior registration event or control of the referenced token: as with the full
pointer, the write is an assertion by the controlled `account`, and an indexer verifies the
reciprocal claim separately. Reject a derived all-ones hash because it aliases the unset sentinel.

No unsigned `counterfactualRegisterAndSetPrimary` helper is required in this release. A collection
registers with the unsigned counterfactual family while the id is ownerless, then uses the direct
or paid `setPrimaryCounterfactualAgent[For]` surface. Gasless counterfactual-primary signatures are
intentionally not supported.

## Events and indexer contract

Retain the full event names, but change `agentId` to `uint256`. This changes the event topic for
`PrimaryAgentSet` and `PrimaryAgentSetWithSig`, so indexers must subscribe to the new topics at the
upgrade block.

```solidity
event PrimaryAgentSet(
    address indexed account,
    uint256 indexed agentId,
    address indexed setBy
);
event PrimaryAgentCleared(
    address indexed account,
    address indexed clearedBy
);
event PrimaryAgentSetWithSig(
    address indexed account,
    uint256 indexed agentId,
    address indexed relayer,
    uint256 nonce
);
event PrimaryAgentClearedWithSig(
    address indexed account,
    address indexed relayer,
    uint256 nonce
);
```

Create a separate counterfactual event family rather than adding a system tag:

```solidity
event PrimaryCounterfactualAgentSet(
    address indexed account,
    bytes32 indexed registrationHash,
    address tokenContract,
    uint256 tokenId,
    address indexed setBy
);
event PrimaryCounterfactualAgentCleared(
    address indexed account,
    address indexed clearedBy
);
```

For direct/paid writes, `setBy`/`clearedBy` is the direct caller. Full-system signed operations
retain their full-system `WithSig` provenance events; counterfactual primaries have no signed
events.

`registerAndSetPrimary` keeps the order `AgentBound` then `PrimaryAgentSet`.

Clears remain idempotent and emit even when already unset. A counterfactual clear cannot include
token coordinates because the mapping intentionally stores only the hash; the preceding set event
is the coordinate-bearing source of truth.

The existing `CounterfactualAgent...` event ABIs remain unchanged, but every indexed
`registrationHash` emitted at or after the `0.0.14` cutover uses the ERC-7930 preimage. Their
signature topic (`topic0`) therefore stays the same while the indexed hash value changes. Indexers
must select the validation algorithm by deployment and cutover block, not by event signature alone.

## Authorization

Use the same direct/paid authorization policy in both systems, without sharing implementation state:

- Self-paid setters and clears act on `msg.sender`.
- `...For` calls use the existing `_controlsAccount(account, msg.sender)` rule: the account itself,
  canonical `owner()`/`getOwner()`, or its `DEFAULT_ADMIN_ROLE`.
- Full-system signed calls are strictly account-self through `SignatureChecker` against `account`
  (EOA or ERC-1271). They do not accept an owner/admin/controller signature.
- Any relayer may submit a valid full-system signed payload.
- The 30-minute maximum deadline, inclusive `deadline == block.timestamp`, and existing
  `SignatureDeadlineTooFar`, `SignatureExpired`, and `InvalidSignature` behavior remain for full
  primaries.

Keep account-control helpers shared and keep signature/deadline validation scoped to the full
system. Storage helpers remain system-specific; no dynamic routing between mappings is permitted.

## EIP-712 and nonce separation

Append one nonce mapping:

- `primaryAgentNonces(account)` for full set/clear.

Full-system operations invalidate competing full-system signatures at the same nonce.
Counterfactual-primary writes have no signature or nonce surface and cannot affect this stream.

Publish these exact new EIP-712 type strings (retaining the existing `Adapter8004` domain):

```text
SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)
ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)
```

The EIP-712 domain remains the standard
`EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with the local
numeric EVM chain id. ERC-7930 does not redefine EIP-712's domain schema. The domain's `chainId`
and `verifyingContract` continue to provide normal EIP-712 replay protection for full primaries.

The changed reverse-pointer type names/fields deliberately invalidate every signature created for
the old mixed surface. Do not reset into a new nonce mapping while retaining an old type hash: that
would make an unused pre-upgrade nonce-zero reverse-pointer signature executable after the cutover.
Signature-based counterfactual registration and counterfactual-primary signatures are removed
entirely.

Remove the ambiguous public `nonces(address)` API from the new interfaces. Do not alias it.
Full-system clients use `primaryAgentNonces(address)`.

## Storage layout and legacy-state policy

Preserve the existing regular slots exactly and append new storage:

| Slot | New source name | Role after the cutover |
|---:|---|---|
| 0 | `identityRegistry` | unchanged |
| 1 | `_bindings` | unchanged |
| 2 | `_primaryAgent` | complement-encoded full `uint256 agentId` |
| 3 | `_primaryCounterfactualAgent` | complement-encoded CF `bytes32 registrationHash` |
| 4 | `_primaryAgentNonces` | full signed-operation nonce |

The active deployed implementations end at slot 1. Unreleased 0.0.9-0.0.13 storage declarations
are not upgrade baselines and reserve no slots. This gives the contract two active pointer
mappings without inventing legacy production state.

Both active mappings store the bitwise complement. A zero storage word means unset and reads as the
system's all-ones sentinel; a real zero ID/hash round-trips; setting all ones reverts with a
system-specific error (`PrimaryAgentIdReserved` for full and
`PrimaryCounterfactualAgentHashReserved` for CF). Private helpers should be statically named
`_setPrimaryAgent`/`_clearPrimaryAgent` and
`_setPrimaryCounterfactualAgent`/`_clearPrimaryCounterfactualAgent`.

No reinitializer is needed: all new mappings begin empty naturally, and migration cannot be
performed correctly from on-chain storage alone.

## Migration and rollout policy

Do not guess whether an old `bytes32` is an agent ID or hash. Value magnitude is not a type proof,
and standalone old setters emitted the same event for both. Therefore a heuristic split, automatic
batch migration, and dual-read compatibility getter are rejected.

The documented production state makes the clean break low risk: versions `0.0.9` through `0.0.13`
are unreleased and the primary-agent selectors are not live on Mainnet, Base, or Sepolia. Before
deployment, make this an explicit gate rather than an assumption:

1. Read each proxy's EIP-1967 implementation slot and record the implementation/version.
2. Confirm the live ABI/bytecode does not expose the primary-agent surface.
3. Scan each proxy from deployment through the intended cutover block for legacy
   `PrimaryAgentSet`, `PrimaryAgentCleared`, and signed audit topics.
4. Record zero matching production events in the upgrade report.

If any target chain fails that gate, stop the rollout. Do not silently ship a different migration
policy. Produce an account/value/event snapshot and choose a separately reviewed remediation:
affected accounts re-attest through the new APIs, or an explicit owner-approved migration contract
is designed from externally verified classifications.

For local, test, or partner proxies that deployed an unreleased build, the supported primary-pointer
migration must be designed separately; they are not compatible with the production 0.0.14 upgrade
path. Old pre-signed full-primary payloads using superseded type hashes are invalid, and the
counterfactual-primary signed surface is removed.

The release is an indexer cutover, not a history rewrite:

- Retain pre-cutover mixed primary events and bare-chain-id counterfactual hashes as explicitly
  versioned legacy data. Never expose an old hash as a `0.0.14` hash.
- At the recorded upgrade block, begin the two independent primary projections and switch validation
  of every counterfactual event's indexed `registrationHash` to the ERC-7930 algorithm. Existing
  counterfactual event signatures/topics do not change merely because the indexed hash value changes.
- Cache the deployment's exact `chainIdentifier()` bytes, adapter
  `interoperableAddress(address(adapter))`, and implementation version with the cutover metadata.
  Do not infer `eip155` solely from a numeric chain-id column.
- Do not replay or re-key historical counterfactual logs into the new namespace. A live claim under
  the new hash requires a post-cutover counterfactual event (or a separately specified, auditable
  migration record). Coordinate-based `oldHash -> newHash` tables may be published for discovery,
  but they are redirects, not proof that the new claim was emitted.
- Never seed either new primary projection from a legacy mixed event without an explicit verified
  migration record.

## Contract implementation sequence

1. Add reusable local ERC-7930 `eip155` builders, expose `chainIdentifier()` and
   `interoperableAddress(address)`, and replace `_registrationHash` with the exact
   `abi.encode(bytes,address,uint256)` preimage containing the adapter's full Interoperable Address
   and the naked token-contract address. Route every counterfactual read/emitter through it; add no
   configurable or caller-supplied hash domain.
2. Replace the mixed NatSpec in `IERC8004AdapterPrimaryAgent` with full-only semantics, change IDs to
   `uint256`, add `primaryAgentNonces`, and update the signed structs/events.
3. Add `IERC8004AdapterCounterfactualPrimaryAgent` with the counterfactual API, events, sentinel,
   and two-way-verification caveat.
4. Make `Adapter8004` implement both interfaces, append the three mappings at slots 2 through 4,
   and add the two complement-encoded helper pairs.
5. Route paid full and CF functions to only their matching helpers. Derive CF hashes from the full
   local adapter Interoperable Address, naked token-contract address, and token id before storage.
6. Keep the full-system reverse-pointer type hashes and nonce consumption. Remove the
   counterfactual-primary typehashes, signed setters/clearers, nonce getter, and `WithSig` events.
   Keep full-system deadline/signature verification utilities and remove the ambiguous shared
   `nonces` getter.
7. Route `registerAndSetPrimary` only to `_setPrimaryAgent`.
8. Remove signature-based counterfactual registration and counterfactual-primary APIs, EIP-712
   payloads/typehashes, helpers, fixtures, events, nonce storage, and tests. Preserve only the
   full-system signed reverse-pointer set/clear APIs.
9. Bump `@custom:version`, update the deployment script's version text, event/hash output, Safe
   transaction description, and "empty initializer/new append-only storage" explanation.

## Tests

Refactor `Adapter8004.primaryAgent.t.sol` into full and counterfactual sections or separate files.
Retain the current account-controller adversarial mocks for both paid `...For` families.

Required functional coverage:

- Fresh accounts return the correct independent unset sentinel.
- Full ID `0` and CF hash `0` are representable; each all-ones sentinel is rejected without a write.
- An account can hold both primaries simultaneously.
- Set, overwrite, idempotent clear, and delegated clear in one system leave the other pointer
  byte-for-byte unchanged.
- Full and CF values that happen to have the same 256-bit representation remain independent.
- CF setters derive exactly `registrationHash(tokenContract, tokenId)` from the local adapter
  Interoperable Address, naked token-contract address, and token id, and emit the coordinates.
- Neither pointer write changes bindings, registry records, or the other system.
- The self/owner/getOwner/default-admin/non-controller matrix is identical for both `...For`
  surfaces, including malformed or reverting controller-discovery calls.

Required ERC-7930/hash coverage:

- Assert the exact mainnet, Base, Sepolia, and Solana-namespace envelope/hash vectors published
  above using the literal bytes, not the production helper as the expected-value oracle.
- Fuzz nonzero `block.chainid` values across every reference-length boundary (1 through 32 bytes);
  assert minimal big-endian encoding, correct length byte, no leading zero, and both the zero-length
  Chain Identifier and 20-byte-address forms.
- Explicitly cover/reject chain id zero in the helper harness.
- Assert `registrationHash` matches
  `keccak256(abi.encode(interoperableAddress(address(adapter)),
  tokenContract, tokenId))` and differs from both the pre-`0.0.14`
  `abi.encode(block.chainid, ...)` hash and the superseded
  `abi.encode(chainIdentifier(), address(adapter), tokenContract, tokenId)` candidate.
- Hold adapter/token coordinates constant and vary only `ChainType`, only `ChainReference`, the
  adapter, token contract, and token id; assert every resulting hash differs.
- Assert `abi.encodePacked`, an adapter naked-address coordinate, a token-contract Interoperable
  Address, and "hash the adapter Interoperable Address first" negative vectors do not match.
- Exercise every counterfactual register/update/wallet/primary path and assert its returned/stored/
  emitted hash equals the one canonical helper result.

Required convenience-helper coverage:

- `registerAndSetPrimary` sets only the full pointer and leaves the CF pointer untouched.
- Direct/paid counterfactual reverse-pointer set/clear leaves the full pointer/nonce untouched.
- A deliberately derived reserved CF hash reverts the pointer write and events atomically in the
  existing harness.

Required full-system signature/replay coverage:

- EOA and ERC-1271 happy paths, rejection, malformed signature, wrong signer, wrong operation,
  tampered field, stale nonce, replay, cross-chain, cross-proxy, expiry, maximum deadline, and
  deadline-equals-now.
- Full-system set and clear share a nonce and invalidate each other.
- Frozen legacy reverse-pointer signatures for old set and clear type strings fail after upgrade
  and consume no new nonce.
- Exact full-system struct-hash/typehash tests use the literal strings published above; the
  EIP-712 domain remains the standard numeric-EVM domain.

Required upgrade/layout coverage:

- Extend the seeded UUPS upgrade harness to populate identity registry and bindings before
  upgrading from the exact live two-slot baseline.
- Assert slots 0 and 1 are unchanged after upgrade.
- Assert both new getters are unset and the full nonce getter is zero.
- Set both new primaries and probe the full nonce slot.
- Commit `forge inspect Adapter8004 storageLayout` comparison evidence showing the three mappings
  appended in slots 2 through 4.
- Add interface-cast and ABI snapshot tests for both interfaces, including selectors and all new
  event topic hashes.

Run at minimum `forge fmt --check`, `forge build`, the two primary-agent test suites, deployment
script tests, and the full `forge test` suite. Because this changes authorization, EIP-712,
ERC-1271, storage, and indexer topics, require the same independent security review gate documented
for `0.0.11` before deployment.

## Documentation and consumer artifacts

Update all references that currently describe a mixed ID space:

- **README:** replace the single primary-agent section with side-by-side full and counterfactual
  sections, include both API tables, sentinel behavior, auth, full-system nonce/event ordering,
  two-way verification, the exact ERC-7930 hash formula, `interoperableAddress(address)`,
  `chainIdentifier()`, and the hard cutover.
- **CHANGELOG:** add a breaking `0.0.14` entry; state that the earlier `0.0.9`-`0.0.13`
  primary-agent designs were never production-deployed and are superseded. List selectors, changed
  topics, EIP-712 types, slots, the new hash domain, and the absence of an initializer.
- **Interfaces/NatSpec:** remove every statement that one bytes32 space holds both kinds. Document
  that full IDs are `uint256`, CF hashes are derived from the exact ERC-7930 bytes plus coordinates,
  standards-profile pinning, and that claims are not proof.
- **Fixtures:** keep `docs/fixtures/adapter-primaryagent-withsig.md` as the full-system fixture and
  rewrite it for `primaryAgentNonces` and the new full type strings. Do not publish a
  counterfactual-primary signature fixture because that API is removed. Add a dedicated
  counterfactual-hash fixture containing the
  exact four cross-chain vectors above, a reference off-chain implementation, explicit
  `(bytes,address,uint256)` `abi.encode` rules, and negative packed/wrong-coordinate vectors.
- **Generated consumer ABI:** regenerate rather than hand-edit. Call out removal of `nonces` and
  old `bytes32` setter selectors plus addition of `chainIdentifier()` and
  `interoperableAddress(address)`. Consumers must not infer the system or chain type from value size.
- **Indexer migration guide:** record the per-deployment cutover block and Chain Identifier; explain
  unchanged counterfactual `topic0` values versus changed indexed hashes, legacy/new namespace
  separation, re-attestation, optional discovery redirects, and the prohibition on silently
  re-keying historical events as new claims.
- **Deployment report/runbook:** record implementation addresses/code hashes, storage-layout
  validation, the zero-legacy-event preflight, cutover blocks, old/new event topics, Safe calldata,
  exact `chainIdentifier()` reads, pre/post-cutover sample hashes, post-upgrade reads, and rollback
  implementations.

## Deployment verification and rollback

Use an empty `upgradeToAndCall` initializer payload. Roll out Sepolia, then Base, then Mainnet, with
an explicit pause after each chain. At each cutover:

1. Verify owner, implementation slot, implementation code hash, version, identity registry, and a
   known binding.
2. Verify `chainIdentifier()` and the adapter `interoperableAddress(...)` value byte-for-byte
   against the chain's pinned ERC-7930/CAIP-350 vectors and verify a known `registrationHash`
   independently with `abi.encode(bytes,address,uint256)`.
3. Verify both unset getters and the full-system nonce getter on a fresh account.
4. On a controlled test account, set both primaries, read both, clear one, and prove the other
   survives.
5. Execute one full signed write and prove it increments the full nonce without affecting the CF
   pointer.
6. Emit a counterfactual test claim, verify its indexed hash uses the new Chain Identifier, verify an
   old-hash calculation does not match, and confirm indexers apply the cutover rule before proceeding.
7. Verify helper event ordering and subscribe indexers to the new primary topic families before
   proceeding.

Rollback is a UUPS upgrade to the recorded prior implementation. Because the new writes occupy
appended slots, rollback does not corrupt slots 0 through 3, but the old implementation cannot read
the new pointers and any transactions accepted after rollback use the old API and bare-chain-id hash
semantics. Therefore rollback is operational containment, not bidirectional data migration: pause
new primary-agent and counterfactual traffic, preserve cutover/rollback blocks and both hash
algorithms, fix forward, and re-upgrade. Do not copy new values into the legacy mixed slot, and do
not treat counterfactual events emitted during the rollback window as ERC-7930-scoped claims.

## Completion criteria

The change is ready only when:

- there are exactly two active pointer mappings and two explicit getters;
- all direct/paid, full-system signed, and combined paths are statically routed to one system;
- both an account's primaries coexist independently, with one full-system nonce stream;
- every counterfactual path uses the adapter's full ERC-7930 v1 Interoperable Address and naked
  token-contract address in the exact preimage
  and the published mainnet/Base/Sepolia/Solana-namespace vectors pass;
- no counterfactual-primary signed type/API/event/nonce remains, while legacy signatures and
  bare-chain-id hashes fail the cutover tests;
- no production migration is invented for unreleased mixed data;
- old signatures cannot execute against fresh nonce streams;
- storage upgrade tests preserve live slots 0 and 1, prove mappings 2 through 4, and full-suite
  tests pass;
- interface, README, changelog, fixtures, generated ABI, deployment tooling, and indexer guidance
  agree on the same names, types, events, Interoperable Address bytes, hash formula, and cutover
  behavior;
  and
- the production legacy-event preflight and independent security reviews are recorded before a Safe
  upgrade is proposed.
