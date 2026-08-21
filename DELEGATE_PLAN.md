# Adapter8004 delegate.xyz Support Plan

Task: `adapter-delegate-plan`

> **Superseded in part.** `rewriteBindingMetadata`, named below as an owner-only function that must
> not accept delegation, no longer exists; it was removed along with `script/MigrateBindingMetadata.s.sol`.
> The delegation rule stated for it is therefore moot rather than wrong. Everything else in this
> document still describes the shipped delegate.xyz behaviour. Kept as the dated design record.

## Sources verified

- `src/Adapter8004.sol`: control is centralized in `_requireController`, `_requireBindingControl`, and `_hasBindingControl`.
- `src/interfaces/IERC8004IdentityRecord.sol`, `IERC8004AdapterRegistration.sol`, `IERC8004AdapterCounterfactual.sol`, `IERCAgentBindings.sol`: public adapter surfaces and event-only counterfactual interface.
- `deployments/2026-05-15-counterfactual-upgrade-report.md`: current proxies and UUPS/storage notes.
- `deployments/2026-05-15-ownership-transfer-to-safe-report.md`: owner is Safe `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` on Ethereum, Base, and Sepolia.
- delegate.xyz v2 docs and repo:
  - Registry address docs: https://docs.delegate.xyz/technical-documentation/delegate-registry/contract-addresses
  - Interface docs: https://docs.delegate.xyz/technical-documentation/delegate-registry/idelegateregistry.sol
  - v2 contract note: https://docs.delegate.xyz/upgrade-to-v2/v2-is-a-separate-contract
  - Source repo: https://github.com/delegatexyz/delegate-registry

## Current Adapter8004 control model

`Adapter8004` binds each ERC-8004 `agentId` to an external token in `_bindings[agentId] = Binding({standard, tokenContract, tokenId})`.

The real on-chain registration and management path is controller-gated:

- `register(...)` and its no-metadata overload call `_requireBindingControl(...)` before minting the ERC-8004 record.
- `setAgentURI`
- `setMetadata`
- `setMetadataBatch`
- `setAgentWallet`
- `unsetAgentWallet`

Those management functions call `_requireController(agentId, msg.sender)`, which loads the stored binding and reverts `UnknownAgent(agentId)` if absent or `NotController(account, agentId)` if `_hasBindingControl(...)` is false.

The current `_hasBindingControl` semantics are:

- ERC-721: controller is `IERC721(tokenContract).ownerOf(tokenId)`.
- ERC-1155: any account with `IERC1155(tokenContract).balanceOf(account, tokenId) > 0`.
- ERC-6909: any account with `IERC6909(tokenContract).balanceOf(account, tokenId) > 0`.

The counterfactual family is also gated, but it is event-only:

- `counterfactualRegister`
- `counterfactualSetAgentURI`
- `counterfactualSetMetadata`
- `counterfactualSetMetadataBatch`
- `counterfactualSetAgentWallet`
- `counterfactualUnsetAgentWallet`

They call `_requireBindingControl(...)` and emit events only. They do not write adapter storage and do not call the ERC-8004 registry.

## delegate.xyz v2 facts

The v2 registry is immutable and deployed at `0x00000000000000447e69651d841bD8D104Bed493` on Ethereum, Base, and Sepolia. The docs also list that same address for Base Sepolia, but Adapter8004 production/test deployment scope here is Ethereum, Base, and Sepolia.

Relevant v2 read functions:

```solidity
function checkDelegateForAll(address to, address from, bytes32 rights) external view returns (bool);
function checkDelegateForContract(address to, address from, address contract_, bytes32 rights) external view returns (bool);
function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights) external view returns (bool);
function checkDelegateForERC1155(address to, address from, address contract_, uint256 tokenId, bytes32 rights) external view returns (uint256);
```

For ERC-721, the specific check includes token-level, contract-level, and wallet-level delegations. For ERC-1155, the check returns a delegated amount; wallet-level or contract-level delegation returns `type(uint256).max` in the implementation. `rights == bytes32(0)` checks only full delegations, while a nonzero `rights` check accepts either full delegation or that specific rights value.

## Recommended product semantics

Implement delegate support for ERC-721 on the existing Adapter8004 surfaces.

That directly solves the stated cold-storage NFT use case: the NFT can remain in a Safe/multisig, the Safe calls delegate.xyz `delegateERC721(hotWallet, tokenContract, tokenId, rights, true)`, and the hot wallet can call `setAgentURI`, metadata setters, wallet setters, and optionally `register` for that NFT.

Do not try to infer ERC-1155/ERC-6909 delegates on the existing no-vault API. The adapter does not store or receive the cold-wallet address for those standards, and there may be many current holders of the same id. Since delegate.xyz checks require a `from` vault address, any implicit guess would either fail legitimate users or authorize against the wrong holder.

## 1. Where authorization plugs in

Keep the integration at the internal authorization layer, not at each public function.

Change the two `_hasBindingControl` overloads so direct current ownership/balance remains the first check, then delegate.xyz is consulted only for standards where the adapter can identify the delegating vault.

Recommended shape:

- ERC-721:
  - Load `owner = IERC721(tokenContract).ownerOf(tokenId)`.
  - If `account == owner`, return true.
  - Else return `_isERC721Delegate(account, owner, tokenContract, tokenId)`.
- ERC-1155:
  - Keep existing `balanceOf(account, tokenId) > 0`.
  - No delegate registry check on the existing API.
- ERC-6909:
  - Keep existing `balanceOf(account, tokenId) > 0`.
  - No delegate registry check on the existing API because delegate.xyz v2 has no ERC-6909 token-id delegation primitive.

Because `register` and all real management functions already funnel through these helpers, this applies to:

- `register(...)` overloads for ERC-721
- `setAgentURI`
- `setMetadata`
- `setMetadataBatch`
- `setAgentWallet`
- `unsetAgentWallet`
- `isController`

`rewriteBindingMetadata` remains owner-only and should not accept delegation.

Counterfactual functions should use the same helper behavior for ERC-721. Even though they are event-only, they are still token-control claims; a delegated hot wallet should be able to emit the off-chain record updates for the same NFT use case. No extra counterfactual-specific storage or events are needed.

## 2. Registry checks and rights

Use `checkDelegateForERC721(msg.sender, owner, tokenContract, tokenId, DELEGATE_RIGHTS)` for ERC-721.

Do not separately call `checkDelegateForContract` or `checkDelegateForAll` for ERC-721 because the v2 `checkDelegateForERC721` implementation already considers token, contract, and all-wallet delegations.

Use a dedicated adapter-management rights constant:

```solidity
bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");
```

Rationale:

- A dedicated rights value lets cold wallets delegate only Adapter8004 management without granting a broad app-agnostic delegation.
- Passing the dedicated nonzero rights still accepts full empty-rights delegations because delegate.xyz v2 checks the empty/full delegation first, then checks the requested rights-specific delegation.
- This produces a practical UX: power users can grant `adapter8004.manage`; users who already use broad delegate.xyz vault delegation still work.

For ERC-1155, only add support in a future explicit-vault API if product requirements demand it. That API would need callers to supply the vault and the adapter would verify both `balanceOf(vault, tokenId) > 0` and `checkDelegateForERC1155(account, vault, tokenContract, tokenId, DELEGATE_RIGHTS) > 0`. That should be a separate design because it requires adding vault parameters or storing vault identity, both of which change the current shared-holder semantics.

For ERC-6909, there is no v2 ERC-6909-specific check. A future explicit-vault path could consider `checkDelegateForContract` or `checkDelegateForAll`, but that would be broader than token-id delegation and should not be silently applied to the existing shared-balance model.

## 3. Registry address configuration

Use a hardcoded constant:

```solidity
address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
```

Rationale:

- This is the canonical v2 address on Ethereum, Base, and Sepolia.
- It avoids new mutable storage and therefore minimizes UUPS storage-layout risk.
- It avoids owner-controlled authorization policy changes after deployment.

Behavior when absent:

- Delegate authorization should fail closed to direct token control only.
- `_isERC721Delegate` should check `DELEGATE_REGISTRY.code.length != 0` before calling the interface. If no code exists, return false.
- If the registry exists but reverts unexpectedly, let the revert bubble. On the three target chains this should not happen; bubbling is better than silently accepting or swallowing a broken authorization dependency. Tests can include the no-code case with a fork or configurable mock-only helper if needed.

Do not add an owner-settable registry address for this upgrade. If a future noncanonical chain is supported, prefer a new deployment profile or a separate upgrade after reviewing that chain's delegate.xyz deployment status.

## 4. Errors, events, storage layout, interfaces

New errors:

- None required. Failed delegated authorization should continue to revert with `NotController(account, agentId)` or `NotController(account, type(uint256).max)` on registration/counterfactual pre-binding checks.

New events:

- None required. The delegate registry already emits delegate/revoke events. Adapter management calls already emit Adapter8004-level mutation events with `updatedBy`/`registeredBy`, which will be the hot wallet when delegated.

Storage layout:

- No new storage variables.
- Add only constants and an interface import/type. Constants do not consume storage slots.
- Existing layout should remain:
  - `identityRegistry` at slot 0
  - `_bindings` at slot 1
  - `ReentrancyGuard` ERC-7201 namespaced storage outside the regular layout
- The implementation must run `forge inspect Adapter8004 storage-layout` before and after, and the regular storage layout should remain byte-identical.

Interface additions:

- Add a minimal local `IDelegateRegistry` interface, either in `src/interfaces/IDelegateRegistry.sol` or inside `Adapter8004.sol` if the team wants to keep the surface small.
- Expose `DELEGATE_REGISTRY` and `DELEGATE_RIGHTS` as public constants for frontends/docs.
- No need to modify `IERC8004IdentityRecord`, `IERC8004AdapterRegistration`, or `IERC8004AdapterCounterfactual` for the ERC-721 integration because the existing function signatures are sufficient.
- Update NatSpec on `isController`, `register`, and the controller-gated functions to say ERC-721 delegate.xyz delegates with `DELEGATE_RIGHTS` are accepted.

## 5. Security considerations

Delegation revocation timing:

- Authorization is checked at call time. If the cold wallet revokes before the hot wallet transaction executes, the hot wallet reverts.
- If revocation and a hot-wallet management transaction are in the mempool concurrently, normal ordering rules apply. This is the same race profile as token transfer vs controller call.

ERC-721 ownership changes:

- Since the adapter checks `ownerOf` at call time and passes that owner as `from`, delegations from a prior owner stop working immediately after token transfer.
- A new owner's delegate works once the new owner creates the delegate.xyz entry.

ERC-1155/ERC-6909 shared-balance interaction:

- Existing semantics are intentionally broad: any positive-balance holder can manage the bound record.
- Without a vault address, delegate checks cannot be soundly mapped to a specific ERC-1155/ERC-6909 holder.
- Do not use `checkDelegateForAll` or `checkDelegateForContract` for multi-token standards on the current API; doing so still requires a `from` address and would not resolve the ambiguity.

Counterfactual path:

- Counterfactual operations are event-only, but they still express token-control claims. ERC-721 delegation should apply there because the use case is the same and the helper reuse is straightforward.
- Indexers should treat `emitter` as the actor and can independently verify delegate status from historical delegate.xyz events if they need audit trails.

Reentrancy:

- All state-mutating external functions already use `nonReentrant`.
- The delegate check is a `view` external call, similar in risk shape to existing `ownerOf`/`balanceOf` calls.
- `checkDelegateForERC721` itself should not call back into the adapter, but the existing reentrancy guard still protects the mutating public entry points.
- Keep direct owner/balance checks first to avoid unnecessary registry calls for current owners.

Dependency risk:

- delegate.xyz v2 is immutable and broadly deployed, but it is still an external authorization dependency.
- The integration should be fail-closed on absent registry bytecode.
- Do not allow the adapter owner to repoint the registry in this upgrade; mutability would turn adapter authorization into an owner-controlled policy surface.

Gas:

- Direct owner calls add only an owner comparison after the existing `ownerOf`.
- Delegated ERC-721 calls add one registry staticcall. The delegate.xyz v2 docs benchmark `checkDelegateForERC721` around 7,932 gas, before normal external call overhead.

## 6. Test plan

Add a mock v2 delegate registry with:

- `delegateERC721(from implicit via prank or helper, to, contract, tokenId, rights, enable)` or direct setter helpers.
- `delegateContract`
- `delegateAll`
- `delegateERC1155` if testing future/negative behavior.
- `checkDelegateForERC721` semantics matching v2: token-specific, contract-level, or all-wallet delegation; empty/full rights accepted when a nonzero rights check is requested.
- `checkDelegateForERC1155` returning amount for explicit negative/future tests if useful.

Because the production address is hardcoded, tests can use `vm.etch(DELEGATE_REGISTRY, address(mock).code)` and initialize mock storage through direct calls if the mock stores state at that address, or deploy the mock at the deterministic address in test setup.

Core tests:

- ERC-721 direct owner still registers and manages.
- ERC-721 hot wallet with token-specific `DELEGATE_RIGHTS` can `register`.
- ERC-721 hot wallet with token-specific `DELEGATE_RIGHTS` can call `setAgentURI`, `setMetadata`, `setMetadataBatch`, `setAgentWallet`, and `unsetAgentWallet`.
- ERC-721 hot wallet delegated with empty rights also works when adapter checks `DELEGATE_RIGHTS`.
- ERC-721 hot wallet delegated at contract level works via `checkDelegateForERC721`.
- ERC-721 hot wallet delegated at all-wallet level works via `checkDelegateForERC721`.
- Wrong rights value fails.
- Revoked delegation fails.
- Prior-owner delegation fails after token transfer.
- `isController(agentId, hotWallet)` returns true for valid ERC-721 delegates and false after revoke/transfer.
- Unknown agent behavior remains `UnknownAgent` for mutating functions and false for `isController`.
- No-code delegate registry behavior: direct owner still works; hot wallet without direct ownership fails.
- ERC-1155 and ERC-6909 behavior is unchanged: direct positive-balance holders work, zero-balance delegates do not become controllers.
- Counterfactual ERC-721 delegate can emit all counterfactual events.
- Counterfactual wrong/revoked delegate reverts with `NotController(account, type(uint256).max)`.
- Reserved metadata key protections still apply for delegated callers.
- Reentrancy adversarial tests still pass.
- Storage layout is unchanged.

Run:

```bash
forge fmt
forge test
forge test --match-path test/security/Adapter8004.*.t.sol
forge inspect Adapter8004 storage-layout
```

If fork RPCs are available, add smoke checks that `DELEGATE_REGISTRY.code.length > 0` on Ethereum, Base, and Sepolia and optionally call `supportsInterface` or a harmless read against the live registry.

## 7. Upgrade and deployment approach

Implementation owner:

- The `adapter` agent owns implementation in `/Users/nxt3d/projects/adapter`.
- `cto` should review the PR/patch before Safe execution because this is an authorization change.

Phased build order:

1. Add the local `IDelegateRegistry` interface, `DELEGATE_REGISTRY`, `DELEGATE_RIGHTS`, and the internal ERC-721 delegate helper.
2. Refactor only the two `_hasBindingControl` overloads to include ERC-721 delegate checks after direct ownership.
3. Add focused delegate registry mock/tests for real and counterfactual ERC-721 paths.
4. Add explicit negative tests proving ERC-1155/ERC-6909 behavior is unchanged.
5. Run full Foundry tests, formatting, and storage-layout verification.
6. Prepare a short upgrade report with implementation addresses, storage-layout hash, tests run, and target proxy addresses.
7. Deploy new implementation and execute `upgradeToAndCall(newImplementation, "")` through the Safe on Sepolia first.
8. Smoke test Sepolia:
   - implementation slot changed
   - `DELEGATE_REGISTRY.code.length > 0`
   - direct owner path still works against a test token/agent where possible
   - delegated ERC-721 path works in a controlled test transaction if practical
9. Repeat Safe upgrade on Base and Ethereum mainnet after Sepolia verification.
10. Post-upgrade report should include proxy, old implementation, new implementation, tx hash, block, storage-layout result, and smoke-test result for each chain.

Current proxies from the 2026-05-15 report:

- Ethereum mainnet: `0xde152AfB7db5373F34876E1499fbD893A82dD336`
- Base: `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`
- Sepolia: `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`

Current owner:

- Safe `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` on all three chains.

Operational note:

- Existing `script/UpgradeAdapter.s.sol` uses `DEPLOYER_PRIVATE_KEY` and calls `upgradeToAndCall` directly. Since ownership has moved to the Safe, the deployment flow must either be adapted to prepare Safe calldata or use Safe Transaction Builder. The deployer EOA can still deploy implementations, but cannot upgrade the proxies directly.
