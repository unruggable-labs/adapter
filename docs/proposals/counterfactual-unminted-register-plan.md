# Implementation plan: counterfactual registration for ownerless token ids

**Source of product intent:** [`counterfactual-unminted-register.md`](./counterfactual-unminted-register.md)  
**Target contract:** `src/Adapter8004.sol`  
**Target source version:** `0.0.13` (unreleased, following current `0.0.12`)  
**Storage migration:** none  
**Event/schema migration:** none

## Decision summary

Extend the existing unsigned counterfactual entry points rather than add an
`Unminted`-specific public function. For ERC-721, ERC-1155F, and ERC-6909F, all
unsigned counterfactual writes will accept either:

1. the existing current-controller authority, or
2. a temporary ownerless authority when the direct caller is the token contract
   itself and `ownerOf(tokenId)` reports no current owner.

The ownerless authority applies to registration, URI, metadata, and wallet
events. This makes the authority rule consistent across the emit-only state
machine and permits a collection to initialize the complete counterfactual
record before mint. It does not apply to either signed function.

Plain ERC-1155 and ERC-6909 remain balance-controlled only. They have no
mandatory global owner or supply query from which the adapter can prove that an
id has no holder. Optional `totalSupply` extensions are not sufficient protocol
grounds and would also make burned/reissued ids inconsistent across
collections.

Pre-mint events retain the existing schema and set `emitter = tokenContract`
(which is also `msg.sender`). There is no zero emitter, provenance flag, new
event, payload-version increment, registration-hash change, or adapter storage.

## Problem and implementation shape

Today every unsigned counterfactual function calls
`_requireBindingControl(...)`. A single-owner token's `ownerOf(tokenId)` reverts
before mint, so the collection cannot emit the identity record immediately
before `_mint`. Creating a second entry point would duplicate the same payload
and event, give integrators two selectors for one state transition, and still
require the setters to make a separate authority decision.

Instead, introduce one internal authorization helper, tentatively:

```solidity
function _requireCounterfactualControl(
    TokenStandard standard,
    address tokenContract,
    uint256 tokenId,
    address account
) internal view;
```

Every existing unsigned counterfactual write calls this helper in place of
`_requireBindingControl`. Its behavior is:

```text
if account == tokenContract
   and standard is ERC721 / ERC1155F / ERC6909F
   and ownerOf(tokenId) reports no owner:
       authorize
else:
       run the existing _requireBindingControl check unchanged
```

The fallback is important. Once an owner exists, the token contract receives no
special treatment, but it may still act if it independently satisfies the
normal controller model—for example, because it currently owns the token or is
a valid delegate. A collection that minted the id to a buyer and has no such
authority receives the existing
`NotController(tokenContract, type(uint256).max)` failure.

Use the helper in all of these existing functions:

- both `counterfactualRegister` overloads, through
  `_counterfactualRegisterImpl`;
- `counterfactualSetAgentURI`;
- `counterfactualSetMetadata`;
- `counterfactualSetMetadataBatch`;
- `counterfactualSetAgentWallet`;
- `counterfactualUnsetAgentWallet`.

Signature-based counterfactual registration is removed. The register-at-mint route is the
collection calling the existing unsigned counterfactual register selector directly while the id
is ownerless, followed by minting. Signed reverse-pointer set/clear APIs remain separate and
unchanged.

No special one-shot state is added. Repeated registration or setter calls while
the id is ownerless emit repeated logs with the same `registrationHash`.

## Token-contract and ownerless detection

### Contract validation

Strengthen `_requireValidTokenContract` to require
`tokenContract.code.length != 0`, in addition to its existing zero-address and
identity-registry exclusions. The ownerless branch must never let an EOA call
with `tokenContract == msg.sender` and masquerade as a collection. This also
turns currently unusable EOA token inputs into a deliberate
`InvalidTokenContract` failure across all adapter paths. Calls made from a token
contract's constructor are not supported because its runtime code is not yet
installed; collection authors should call the adapter from a normal mint
function after deployment.

### Exact `ownerOf` probe

Only probe `ownerOf` after contract validation, only when
`account == tokenContract`, and only for the three single-owner standards. Use a
low-level `staticcall` rather than Solidity `try/catch` so malformed successful
return data can be separated from a revert:

```text
staticcall ownerOf(tokenId)
  call reverts                         => no current owner
  succeeds with canonical address(0)   => no current owner
  succeeds with canonical nonzero addr => currently owned
  succeeds with malformed data         => revert InvalidOwnerOfResponse
```

A canonical response is exactly one 32-byte ABI word with no nonzero bits above
bit 159. Add a precise error such as
`InvalidOwnerOfResponse(address tokenContract, uint256 tokenId)` for a
successful call with a wrong-length or dirty address result. This is
fail-closed: malformed success must not create an ownerless window.

Treat a reverted call as ownerless because standard ERC-721-style `ownerOf`
signals a nonexistent id by reverting and does not standardize one universal
revert selector. A successful zero address is also treated as ownerless to
support collections that use that convention, even though ordinary ERC-721
implementations revert.

This rule relies on the collection truthfully implementing the selected
single-owner profile. A malicious collection can make `ownerOf` revert for an
owned id, but the only additional authority it thereby grants is to that same
token contract, which already controls issuance and all pre-mint emissions.
Consumers should already treat claims from a nonconforming token contract as
untrusted. The adapter cannot prove historical mint state without storage.

Consequently, “unminted” is implemented as **no current owner**. If a token is
burned and its `ownerOf` again reverts or returns zero, the collection-only
window reopens. Preventing that would require the explicitly rejected one-shot
SSTORE or a mandatory historical-existence API. Document this edge case rather
than implying permanent first-mint tracking.

The external call remains inside the existing `nonReentrant` guard. Add a
reentrancy test proving an `ownerOf` callback cannot enter another
counterfactual write.

## API and event semantics

### Public ABI

Do not add a new public selector. The calldata and return values of every
existing function stay unchanged. In particular:

```solidity
counterfactualRegister(
    TokenStandard standard,
    address tokenContract,
    uint256 tokenId,
    string agentURI,
    MetadataEntry[] metadata
) returns (bytes32 registrationHash)
```

is the collection's register-at-mint API. The collection passes its own address
as `tokenContract`; direct calling—not `delegatecall`, a router, or a forwarded
sender—is what establishes collection authority.

The recommended collection flow is:

```solidity
function mint(address buyer, uint256 tokenId, /* CF payload */) external {
    adapter.counterfactualRegister(
        TokenStandard.ERC721,
        address(this),
        tokenId,
        agentURI,
        metadata
    );
    // Optional counterfactualSetAgentWallet / other setters go here.
    _mint(buyer, tokenId);
}
```

Register first and mint second in the same transaction. Reversing the calls
closes the special window before the adapter check. If any later operation
reverts, EVM atomicity removes the earlier counterfactual logs as well.

### Events and indexing

Continue emitting the existing events with
`COUNTERFACTUAL_PAYLOAD_VERSION == 1`. For the ownerless path, `emitter` is the
actual authorized caller, `tokenContract`. `address(0)` would discard useful
provenance, while adding a flag or changing an event would change `topic[0]` and
force an unnecessary schema migration.

Indexers should:

- key the record by the `0.0.14` `registrationHash`, derived from
  `(interoperableAddress(adapter), tokenContract, tokenId)`;
- order events by `(blockNumber, transactionIndex, logIndex)`;
- treat a later `CounterfactualAgentRegistered` as the latest full registration
  payload and later setter events as field updates;
- retain `emitter == tokenContract` as collection-authorized provenance;
- allow a later owner/controller event to overwrite a pre-mint value without
  giving the collection event any priority.

`emitter == tokenContract` identifies who authorized the log, not a permanent
“pre-mint” fact: the token contract could also be the real owner or delegate
after mint. An exact provenance flag is not needed for authorization or
latest-event-wins resolution. If a future consumer requires that distinction,
it should be introduced as a separately designed versioned event rather than
retrofit into this release.

## Standard policy

| Standard | Ownerless collection window | Detection | Post-mint authority |
|---|---:|---|---|
| ERC-721 | Yes | `ownerOf(tokenId)` | Existing owner/delegate checks |
| ERC-1155F | Yes | `ownerOf(tokenId)` | Existing owner/delegate checks |
| ERC-6909F | Yes | `ownerOf(tokenId)` | Existing owner/delegate checks |
| ERC-1155 | No | None | Existing positive-balance check |
| ERC-6909 | No | None | Existing positive-balance check |

Do not use `balanceOf(tokenContract, tokenId) == 0`, guessed recipients, optional
`totalSupply`, or a scan of holders to infer that a plain multi-token id is
unminted. The plain standards continue to support their current unsigned
holder-controlled calls after mint and their existing signed paths.

## Contract work breakdown

1. In `src/Adapter8004.sol`, bump `@custom:version` from `0.0.12` to `0.0.13`.
2. Extend `_requireValidTokenContract` with the deployed-code check.
3. Add the malformed-owner-response custom error and a private/internal
   ownerless probe using `staticcall`.
4. Add `_requireCounterfactualControl` and route only the six unsigned
   counterfactual write implementations through it.
5. Leave `_requireBindingControl`, `_requireDirectControl`,
   `_hasBindingControl`, signature hashing, registration hashing, constants,
   storage declarations, and event declarations unchanged.
6. Update NatSpec in `Adapter8004.sol` and
   `src/interfaces/IERC8004AdapterCounterfactual.sol` to state the two
   authorization modes, supported standards, ownerless/burn behavior, direct
   caller requirement, and emitter semantics. Do not add unsigned declarations
   solely for this feature: those selectors already live on `Adapter8004`, and
   the current interface is intentionally the stable counterfactual
   event/signed-function surface.
7. Run formatting, the focused tests, the complete Foundry suite, and a storage
   layout comparison.

## Test plan

Add a focused Foundry suite, for example
`test/security/Adapter8004.counterfactual-unminted.t.sol`, with collection mocks
that both expose `ownerOf` and call the adapter from their own mint functions.
Use real log assertions, not only “does not revert.”

### Core authorization and ordering

- ERC-721 collection can call each `counterfactualRegister` overload for an
  ownerless id; the returned hash matches `registrationHash`, the event payload
  is unchanged, and `emitter == tokenContract`.
- A collection can call URI, single metadata, batch metadata, wallet set, and
  wallet unset while the id is ownerless.
- A stranger calling for the same ownerless id reverts `NotController`; an EOA
  using itself as `tokenContract` reverts `InvalidTokenContract`.
- A mint helper performs register-then-mint atomically; assert registration log
  precedes the token's `Transfer`/mint log and final `ownerOf` is the buyer.
- A mint-then-register helper reverts when the collection is not the new owner
  or delegate. Assert the transaction leaves neither the mint nor the
  registration log/state behind after the expected whole-transaction revert.
- After mint to a buyer, direct collection calls to every unsigned CF function
  revert under the normal controller check.
- The buyer can re-register or use every setter after mint; an authorized
  delegate for a single-owner standard can do the same. Their later event wins
  by log order and carries the actual owner/delegate emitter.
- If the collection itself owns the minted token or is a valid delegate, its
  call succeeds through normal controller authority, demonstrating that the
  ownerless shortcut—not the address—is what closed.

### Repetition and state neutrality

- Emit two or more registrations before mint with different URI/metadata;
  assert the same hash, distinct ordered logs, and the last payload is the one
  an indexer will apply.
- Mix registration and setter events before mint and assert deterministic log
  ordering.
- Record adapter and registry storage accesses/baseline state to prove this path
  does not mint a registry identity, write `_bindings`, change nonces/primary
  state, or add any new adapter SSTORE.
- Burn a previously minted id in a mock whose `ownerOf` reverts afterward and
  assert that only the collection can use the reopened ownerless window. This
  locks in the unavoidable no-current-owner semantics.

### Detection and standard matrix

- Repeat the pre-mint happy path and post-mint closure tests for ERC-721,
  ERC-1155F, and ERC-6909F.
- Add an owner mock that returns `address(0)` for a missing id; assert it opens
  the window and a later nonzero owner closes it.
- Add wrong-length and dirty-upper-bit successful `ownerOf` mocks; assert
  `InvalidOwnerOfResponse` and no log.
- Add an `ownerOf` mock that attempts adapter reentry; assert the existing
  reentrancy error and no persisted log.
- For plain ERC-1155 and ERC-6909, assert a collection with zero balance cannot
  use the ownerless path. Preserve positive-holder unsigned behavior.
- Preserve tests for invalid zero token, registry-as-token, reserved metadata
  keys, registration-hash stability, payload version, and repeated emissions.

Run at minimum:

```sh
forge fmt --check
forge test --match-path test/security/Adapter8004.counterfactual-unminted.t.sol
forge test
forge inspect Adapter8004 storageLayout
```

The implementation PR should attach the before/after `storageLayout` diff and
show no change to existing slots.

## Documentation and release work

Update the following in the implementation PR:

- `README.md`: add the collection register-then-mint example, direct-caller
  constraint, three supported standards, plain ERC-1155/6909 exclusion,
  repeated/latest-event-wins behavior, post-mint controller transition, and
  burned-id caveat.
- `CHANGELOG.md`: add an unreleased `0.0.13` entry explicitly stating no storage,
  selector, registration-hash, event-topic, or EIP-712 changes.
- `src/Adapter8004.sol` and
  `src/interfaces/IERC8004AdapterCounterfactual.sol`: update NatSpec as described
  above.
- Deployment/release notes generated by
  `script/DeployAdapterImplementation.s.sol`: label the new source version and
  explain the authorization change; do not claim it is live until each proxy's
  Safe upgrade is executed and verified.
- Indexer integration notes: document ordering and
  `emitter == tokenContract` provenance before enabling collection integrations.

Mark the original proposal implemented only after the implementation,
security review, and deployment decision are complete; this plan alone does not
change its proposal status.

## Upgrade and compatibility

This is a UUPS implementation-only upgrade. Deploy a new `Adapter8004`
implementation and prepare `upgradeToAndCall(newImplementation, bytes(""))` for
the owner Safe. There is no initializer or reinitializer call because there is
no new state.

Compatibility invariants:

- storage slots and initialization state are byte-for-byte unchanged;
- all existing selectors and return encodings are unchanged;
- all counterfactual event signatures/topics and payload version `1` are
  unchanged;
- this ownerless-authority slice does not independently alter `registrationHash` or either EIP-712
  domain/typehash; it inherits the locked `0.0.14` full-Interoperable-Address hash cutover;
- existing unsigned controller paths and signed reverse-pointer paths remain available;
- calls that pass an EOA as `tokenContract` change from incidental downstream
  call failure to explicit `InvalidTokenContract`, which is an intentional
  hardening change.

Before proposing a Safe transaction, run the full test suite, compare storage
layouts, deploy and verify the implementation, confirm its runtime code hash,
and obtain a security review focused on the external `ownerOf` callback,
malformed return handling, authority fallback, and ownerless-after-burn
semantics. Roll out per chain using the repository's existing implementation
deployment process and verify the EIP-1967 implementation slot after each Safe
execution.

## Acceptance checklist

- A deployed ERC-721/1155F/6909F collection can emit the complete CF record for
  an ownerless id without a signature and mint that id to the buyer later in
  the same transaction.
- Only the token contract receives the special ownerless authority.
- Once `ownerOf` returns a real owner, the special path is closed and the
  existing controller model decides the call.
- Plain ERC-1155/6909 do not gain an ownerless path.
- Multiple pre-mint emissions are allowed and require no SSTORE.
- Owners and delegates can overwrite collection emissions after mint.
- Signed paths, hash domains, events, payload version, and registry behavior are
  unchanged.
- The proxy upgrade requires no storage migration or initialization call.
