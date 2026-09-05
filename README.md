# ERC-8004 Identity Adapter

## Version

The contract version is recorded once, as `@custom:version` in [`src/Adapter8004.sol`](./src/Adapter8004.sol). Repo source is unreleased and not live on-chain; see [Deployments](#deployments).

---

This project lets an external token control an ERC-8004 `IdentityRegistry` record while the adapter proxy remains the on-chain owner of the ERC-8004 identity token.

## How It Works

Registration flow:

```text
  ┌──────────────┐
  │ Token holder │
  └──────────────┘
         │
         │ register(standard, boundAddress, tokenId, agentURI)
         ▼
  ┌──────────────┐      register       ┌─────────────────────┐
  │   Adapter    │ ──────────────────▶ │  ERC-8004 Registry  │
  └──────────────┘                     └─────────────────────┘
         ▲                                      │
         │        mints agent NFT to adapter    │
         └──────────────────────────────────────┘
```

The token holder proves control of an external token and calls `register` on the adapter. The adapter registers the identity in the ERC-8004 registry, which mints the agent NFT to the adapter. The adapter keeps owning the identity and records the binding back to the external token.

Control transfer:

```text
  ┌─────────┐   transfer NFT #1   ┌─────────┐
  │  Alice  │ ──────────────────▶ │   Bob   │
  └─────────┘                     └─────────┘
       │                               │
       │            control            │
       └───────────────┬───────────────┘
                       ▼
             ┌───────────────────┐
             │      Adapter      │
             │  owner check on   │
             │      NFT #1       │
             └───────────────────┘
                       │
                       │ forwards only for the current owner
                       ▼
             ┌───────────────────┐
             │  ERC-8004 agent   │
             │ (owned by adapter)│
             └───────────────────┘
```

The ERC-8004 agent NFT never moves; it stays owned by the adapter. Either party can call the adapter, but the adapter checks the current owner of NFT #1 on every call and forwards only for whoever holds it now. So before the transfer Alice controls the agent, and the moment NFT #1 moves to Bob, Bob does, with no transaction on the agent itself.

## Details

The adapter writes canonical ERC-8004 binding metadata in the format defined by [ERC-8217: Agent NFT Identity Bindings](https://eips.ethereum.org/EIPS/eip-8217), the agent-binding discovery standard (merged into Ethereum/ERCs, originally PR [#1648](https://github.com/ethereum/ERCs/pull/1648)). ERC-8217 is a Draft, so it is not yet finalized and the format may still change. The reserved `agent-binding` key holds the 20-byte binding-contract address (this adapter proxy), and a verifier reads the full token coordinates from `bindingOf(agentId)`.

The binding contract and the bound token contract can be different contracts or the same contract. This repo uses a separate adapter contract, but the metadata format and ERC flow also support token contracts that implement the binding interface themselves.

Supported binding standards:

- ERC-721
- ERC-1155
- ERC-6909
- ERC-1155F
- ERC-6909F
- `ACCOUNT`, an account-level binding of any address, contract or externally owned, including but not limited to an ERC-20 (see [Account-Level Bindings](#account-level-bindings))
- `CONTRACT_OWNABLE`, an explicit-opt-in contract binding controlled by the contract's current `owner()`
- `CONTRACT_ADMIN`, the same idea for an AccessControl contract, controlled by holders of its `DEFAULT_ADMIN_ROLE`

What the unreleased source adds over the active deployments (on-chain status varies by chain — see [CHANGELOG.md](./CHANGELOG.md): the counterfactual register family is live on all three proxies, delegate.xyz support is live on Sepolia only, and the wallet-id surface is not yet deployed anywhere):

- delegate.xyz v2 hot/cold control for single-owner bindings: a delegated hot wallet can drive an ERC-721-, ERC-1155F-, or ERC-6909F-bound agent while the token stays in cold storage.
- A counterfactual register family: emit-only mirrors of the register surface that produce no registry write and no SSTORE, for off-chain identities that can later be promoted on-chain.
- Direct collection register-at-mint for ownerless ERC-721/ERC-1155F/ERC-6909F ids through the existing unsigned counterfactual selectors.
- Account bindings (`ACCOUNT`): any address, whether a deployed contract or an externally owned account, can register and manage agents for itself, at the fixed `tokenId` `0`, with no holder or admin authority. An ERC-20 claiming its own identity is the motivating example.
- Ownable contract bindings (`CONTRACT_OWNABLE`): authority is the bound contract's current canonical nonzero `owner()`, and delegate.xyz delegates of that owner, also at `tokenId` `0`. The bound contract itself has no authority under this standard.
- Admin contract bindings (`CONTRACT_ADMIN`): authority is any holder of the bound contract's `DEFAULT_ADMIN_ROLE`, also at `tokenId` `0`, for an AccessControl contract that exposes no `owner()`. The bound contract itself has no authority under this standard.
- Primary-agent reverse resolution: an `address => agent id` mapping so any consumer can go from a wallet address (or any address recorded in agent metadata) to the agent it claims to belong to, on this chain.

## What The Adapter Does

The adapter changes the control model from:

- plain ERC-8004: controller is `ownerOf(agentId)` on the ERC-8004 registry

to:

- adapter model: controller is the holder of a bound external token

The adapter itself owns the ERC-8004 token permanently. The external token holder does not own the ERC-8004 NFT directly, but can manage the record through the adapter.

## Control Rules

Each ERC-8004 `agentId` is bound once to exactly one external token:

- ERC-721: controller is `ownerOf(tokenId)`, or a hot wallet that holds a delegate.xyz v2 delegation from the current owner
- ERC-1155: controller is any account with `balanceOf(account, tokenId) > 0`
- ERC-6909: controller is any account with `balanceOf(account, tokenId) > 0`
- ERC-1155F: controller is `ownerOf(tokenId)`, or a hot wallet that holds a delegate.xyz v2 ERC-721-style delegation from the current owner
- ERC-6909F: controller is `ownerOf(tokenId)`, or a hot wallet that holds a delegate.xyz v2 ERC-721-style delegation from the current owner
- `ACCOUNT`: controller is the bound address itself, and only that address, permanently; `tokenId` must be `0`
- `CONTRACT_OWNABLE`: controllers are the current canonical nonzero address returned by the bound contract's `owner()`, and delegate.xyz delegates of that owner; the bound contract itself is not a controller; `tokenId` must be `0`
- `CONTRACT_ADMIN`: controllers are holders of the bound contract's `DEFAULT_ADMIN_ROLE`; the bound contract itself is not a controller; `tokenId` must be `0`

The binding is immutable at the agent level:

- the adapter does not expose any rebinding function
- a single external token may register multiple ERC-8004 agents

Important consequence:

- ERC-1155 and ERC-6909 can create shared control if multiple accounts hold balance for the bound token id
- ERC-1155F and ERC-6909F use the `ownerOf` profile defined by ERC-8276 (Non-Fungible Multi-Token `ownerOf`), in review as Ethereum/ERCs PR [#1767](https://github.com/ethereum/ERCs/pull/1767), so they have single-owner control even though the underlying token family is not ERC-721

That is intentional. The adapter preserves the ownership semantics of the bound standard instead of inventing a synthetic single owner.

This controller model is adapter-specific. The ERC draft standardizes binding discovery and binding verification, not universal controller semantics.

### Hot/Cold Delegation

For ERC-721, ERC-1155F, and ERC-6909F bindings, control also passes through the canonical delegate.xyz v2 registry:

- registry: `0x00000000000000447e69651d841bD8D104Bed493` (same address on Ethereum, Base, and Sepolia)
- rights: `keccak256("adapter8004.manage")`, or an empty/full delegation

A cold wallet that owns the bound token can delegate a hot wallet through delegate.xyz, and that hot wallet may then drive the agent without moving the token. Direct ownership is checked first, so a current owner never pays the extra registry call. The check fails closed: if the delegate.xyz registry has no code on a given chain, only direct ownership authorizes.

ERC-1155F and ERC-6909F reuse the delegate.xyz `checkDelegateForERC721` path because they expose single-owner `ownerOf(tokenId)` semantics. Plain ERC-1155 and ERC-6909 use balance checks alone, because the no-vault delegate.xyz API cannot soundly map a token-id delegation to a balance holder.

### Account-Level Bindings

`ACCOUNT` is value `5`, `CONTRACT_OWNABLE` is appended as value `6`, and `CONTRACT_ADMIN` as value `7`. Values `0`-`4` are unchanged. Value `5` keeps its position and was renamed from `CONTRACT`, which moves no stored binding and no indexed history.

Values `0`-`4` name a token *within* a contract, so their binding coordinate is `(boundAddress, tokenId)`. Values `5`, `6` and `7` name an address itself rather than a token within it, so there is no token to identify:

- `tokenId` MUST be `0` for all three values. An account-level binding has exactly one canonical coordinate. Any other id reverts `NonZeroTokenIdForAccount(boundAddress, tokenId)`; the adapter rejects rather than silently coercing to `0`, so the caller's binding and the UBID always match the id submitted. The check runs at both authority choke points, covering `register` and every unsigned counterfactual writer.
- Under `ACCOUNT` (value `5`), the controller is the bound address itself, and only that address. There is no holder, delegate, owner, or admin route in. A large token balance grants nothing, an optional `owner()` on the bound contract grants nothing, and the adapter admin grants nothing. The adapter makes zero external authority calls on this branch: it probes neither `ownerOf`, `owner()`, nor either `balanceOf` shape. This is the permanent-controller model; the bound address never loses authority.
- Under `CONTRACT_OWNABLE` (value `6`), authority is the contract's current `owner()` and delegate.xyz delegates of that owner, and **not** the bound `boundAddress` itself. Choosing value `6` is the binding contract's explicit opt-in to that probe. Self-authority is deliberately excluded: any contract with a generic call mechanism, an upgradeable implementation, or an inducible callback could otherwise seize its own identity without the owner acting, while the name of the standard promises the owner controls it. A contract that wants to control its own identity binds as `ACCOUNT` instead.
- Under `CONTRACT_ADMIN` (value `7`), authority is any holder of the bound contract's `DEFAULT_ADMIN_ROLE`, which is `bytes32(0)`, and nobody else. It exists for an AccessControl contract that exposes no `owner()`, which could otherwise only bind as `ACCOUNT` and route every identity update through its own code. This authorizes identity management only; a wallet's reverse UBID claim must come from the wallet itself.
- **`ACCOUNT` accepts any address, with or without runtime code.** It is the only standard that applies no code test, and it can afford not to because it is the only one that never calls the address it names: authority is the single comparison `msg.sender == boundAddress`. Every other standard still requires code, because `ownerOf`, `balanceOf`, `owner()` or `hasRole` must be callable, and a code-less address reverts `InvalidBoundAddress`. The zero address and the identity registry are rejected under every standard, `ACCOUNT` included.
- **EIP-7702 changes what `ACCOUNT` authority means, and this is worth reading before using it.** A delegation designator puts code behind an externally owned account, so `msg.sender == boundAddress` is not proof of key possession. Authority is precisely *whoever can cause a call to originate from that address*: the key holder, plus anyone able to drive the delegate to make an outbound call if a delegation is installed. **An address bound as `ACCOUNT` can install a delegation afterwards, permanently widening who can act for that identity, and a binding is immutable so this cannot be undone.** Revoking the delegation narrows the set again. This is the same accepted shape as a `CONTRACT_OWNABLE` contract renouncing ownership: an action taken outside the adapter, by the party the standard trusts, that permanently changes who can authorize. Counterfactual claims are less exposed, because they are emit-only and last-event-wins, so a key holder who revokes can re-emit and win again.

- The value-7 `hasRole(bytes32,address)` probe is a `STATICCALL` and fails closed. A revert, returndata whose length is not exactly 32 bytes, or a zero word each grant nobody. Any non-zero word counts as holding the role, which is deliberately more permissive than the value-6 address probe: there is no value being extracted, so a non-canonical `true` from an honest implementation is accepted rather than reverted. Role membership is read on every call, so revoking the role removes authority in the same transaction.
- `CONTRACT_ADMIN` has no delegate.xyz route, by design rather than omission. Delegation requires one delegator to ask the registry about, and a role is a membership predicate that many addresses can satisfy and none can enumerate, so there is no well-defined delegator to name.
- Value-6 owner authority is dynamic. A successful ownership transfer immediately gives control over every existing value-6 binding to the new owner and removes it from the previous owner. This is deliberately different from value 5's permanent sole-controller guarantee.
- The value-6 `owner()` probe is a `STATICCALL` and fails closed. A revert, returndata whose length is not exactly 32 bytes, a word with dirty upper bits, or any other non-canonical shape grants no owner authority. A canonical `address(0)` also grants nobody; it never authorizes the zero account. There is no contract-self fallback in any of those cases, so a binding whose `owner()` cannot be resolved has no authority at all.
- None of the three account-level standards is part of the single-owner token set, so none gets the ownerless-collection window. Only `CONTRACT_OWNABLE` has a delegate.xyz route. `ACCOUNT` has none by design: the delegator would be the bound address itself, and a delegation it granted for any unrelated purpose would otherwise confer permanent control over the identity, which an immutable binding could never withdraw.

An ERC-20 claiming its own identity is the motivating example: it has one fungible supply and no per-token owner, so `ACCOUNT` is how it binds. There is no ERC-20-specific standard value. An ERC-20 uses `ACCOUNT` like any other contract. (ERC-20Agent, if you have seen it referenced, is a separate metadata profile layered on top; it is not a binding standard here.)

Calling rules:

- For `ACCOUNT`, the adapter's immediate EVM caller must be `boundAddress`. A router, forwarder, or multicall contract that calls the adapter itself fails because the adapter sees that intermediary as `msg.sender`.
- For `CONTRACT_OWNABLE`, the immediate caller must be the current canonical nonzero `owner()` returned by the bound contract, or a delegate.xyz delegate of that owner. The bound contract, holders, the adapter admin, roles, and strangers gain nothing from this model.
- For `CONTRACT_ADMIN`, the immediate caller must hold the bound contract's `DEFAULT_ADMIN_ROLE`. The bound contract, holders, the adapter admin, and strangers gain nothing from this model.
- For `CONTRACT_OWNABLE` and `CONTRACT_ADMIN`, a call from the bound contract's constructor fails, because the adapter requires deployed runtime code at `boundAddress` and there is none yet. The same holds for values `0`-`4`. Under `ACCOUNT` it succeeds: no code test applies, and `msg.sender` during construction is already the contract's final address, so a contract can bind itself as `ACCOUNT` from its own constructor.
- Do not `delegatecall` into `Adapter8004`. That is unsupported and dangerous. The adapter is a UUPS proxy implementation with its own storage layout, and borrowing its code into another contract's storage is not a supported integration. This is about calling *into* the adapter; how the bound contract is implemented internally is its own business, and a contract that is itself a proxy binds fine because its proxy address is the caller the adapter sees.

That value-5 call requirement has a design consequence worth stating plainly, and it applies only where the bound address is a contract: **permanent self-authority is worth nothing unless the bound contract has a repeatable outbound path to the adapter.** A contract with no way to call out cannot bind under value 5, and one with only a single hook can bind once and then freezes. That hook may be the constructor. An owner-driven contract that intentionally wants direct external-owner management should choose `CONTRACT_OWNABLE` at bind time instead. An externally owned account has no such constraint, since sending a transaction is itself the outbound path.

Excluding self-authority from value `6` has a consequence at deployment time, because registration runs the same authority check as every other write: **a contract cannot create its own `CONTRACT_OWNABLE` binding.** The owner must call `register`. A contract that registers itself from its constructor or an init hook must either become a two-step deploy, where the owner registers after deployment, or bind as `ACCOUNT` instead.

A second consequence follows from the `owner()` probe failing closed: **`renounceOwnership()` permanently freezes a `CONTRACT_OWNABLE` identity.** With no owner there is nobody left to authorize and no contract-self fallback, so the binding can be neither managed nor, if it does not yet exist, created. This is intended. Renouncing ownership means giving up control.

After binding, the mutable ERC-8004 fields (`setAgentURI`, `setMetadata`, `setMetadataBatch`, `setAgentWallet`, `unsetAgentWallet`) follow the selected authority model, and the latest authorized write wins. The adapter keeps no history and no per-field lock.

The `Binding` itself is immutable for all three values and there is deliberately **no revoke or unbind API**. Once an agent is bound, its selected standard and coordinates are permanent. Dynamic value-6 owner authority does not mutate the binding. To move on, register a fresh ERC-8004 identity instead; a single address may bind any number of agents.

## Architecture

- proxy: `ERC1967Proxy`
- implementation: UUPS upgradeable adapter
- admin: `owner()` on the adapter
- registry pointer: stored in adapter storage and changeable by admin

Main contract:

- [`src/Adapter8004.sol`](/Users/nxt3d/projects/adapter/src/Adapter8004.sol)

Deployment scripts:

- [`script/DeployAdapter.s.sol`](/Users/nxt3d/projects/adapter/script/DeployAdapter.s.sol) (initial proxy + implementation)
- [`script/DeployAdapterImplementation.s.sol`](/Users/nxt3d/projects/adapter/script/DeployAdapterImplementation.s.sol) (implementation-only build for a UUPS upgrade, auto-emits Safe TX JSON)
- [`script/UpgradeAdapter.s.sol`](/Users/nxt3d/projects/adapter/script/UpgradeAdapter.s.sol)
- [`script/TransferAdapterOwnership.s.sol`](/Users/nxt3d/projects/adapter/script/TransferAdapterOwnership.s.sol)
- [`script/deploy.sh`](/Users/nxt3d/projects/adapter/script/deploy.sh)

Interfaces:

- [`src/interfaces/IERC8004IdentityRegistry.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERC8004IdentityRegistry.sol)
- [`src/interfaces/IERC8217.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERC8217.sol)
- [`src/interfaces/IERC8004AdapterRegistration.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERC8004AdapterRegistration.sol)
- [`src/interfaces/IERC8004AdapterCounterfactual.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERC8004AdapterCounterfactual.sol)
- [`src/interfaces/IERC8004IdentityRecord.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERC8004IdentityRecord.sol)
- [`src/interfaces/IDelegateRegistry.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IDelegateRegistry.sol)

Deployment report:

- [`deployments/2026-04-05-deployment-report.md`](/Users/nxt3d/projects/adapter/deployments/2026-04-05-deployment-report.md)

## Deployments

Initial deployment date:

- `2026-04-05`

ERC-8004 `IdentityRegistry` addresses:

- Ethereum mainnet: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`
- Base: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`
- Sepolia: `0x8004A818BFB912233c491871b3d84c89A494BD9e`

Adapter proxy addresses:

- Ethereum mainnet: `0xde152AfB7db5373F34876E1499fbD893A82dD336`
- Base: `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`
- Sepolia: `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`

Current live implementation addresses (verified via the EIP-1967 slots; see the [upgrade-baseline audit](./deployments/upgrade-baseline-from-last-deployed.md)):

- Ethereum mainnet: `0xa6D23f27D3b1780B12488482a008cB3c3787135f` (2026-05-15 counterfactual build)
- Base: `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` (2026-05-15 counterfactual build)
- Sepolia: `0x31a68E5bc0224ad081d6Ec20229B05F558609257` (delegate.xyz build)

Admin (Safe v1.4.1 multisig, same address on all three chains):

- `0x03302Df40186D9B85faEA4fbb6cC5da028B23149`

Previously held by EOA `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` until the 2026-05-15 transfer (see [`deployments/2026-05-15-ownership-transfer-to-safe-report.md`](./deployments/2026-05-15-ownership-transfer-to-safe-report.md)).

Users and integrators should interact with the proxy addresses, not the implementation addresses.

Implementation upgrades are governed by the Safe multisig through UUPS. The [`deployments/`](./deployments) folder records executed upgrades, implementation-only deployments, and prepared Safe payloads; those are different states. The `0.0.6` payloads were not executed, and the purported Mainnet implementation address came from a dry run and has no code. Confirm the live EIP-1967 implementation slot before relying on a version on any chain.

The unreleased implementation upgrades directly from the active
Mainnet/Base May 15 build or the active Sepolia delegate.xyz build—not from
unreleased numbered source versions. Both live layouts populate only regular
slots 0 and 1. Slot 0 held `identityRegistry`, which is now `immutable` and lives in the
implementation's runtime code instead, so slot 0 becomes dead and is reserved
forever by a placeholder; regular storage now begins at slot 1 with `_bindings`.
The two new wallet-id mappings append directly at slots
2 and 3. Existing proxies must use empty
`upgradeToAndCall` data; `initialize(...)` is only for a new proxy. No storage
migration or reinitializer is required. Sepolia's delegate.xyz getters and
authorization remain present.

## Flow

### 1. Deploy

You deploy:

- an adapter implementation
- an `ERC1967Proxy`
- the implementation is constructed with `identityRegistry`, which is baked into its
  runtime code and can never change
- the proxy is initialized with `initialOwner` / admin only

After deployment:

- users interact with the proxy address
- the admin can upgrade the adapter, but only to an implementation carrying the same registry
- nobody can repoint `identityRegistry`, the admin included

### 2. Register A Bound Agent

A current controller, or a supported single-owner collection registering before mint, calls:

```solidity
register(standard, boundAddress, tokenId, agentURI, metadata)
```

The adapter does this:

1. verifies the caller currently controls the external token, or that the direct caller is the
   ERC-721/ERC-1155F/ERC-6909F `boundAddress` and `ownerOf(tokenId)` reports no current owner
2. rejects user metadata that tries to overwrite the canonical binding record
3. calls `identityRegistry.register(...)`
4. becomes owner of the new ERC-8004 identity token
5. stores the immutable binding on that `agentId`
6. writes canonical binding metadata under `agent-binding` (the 20-byte adapter proxy address)
7. immediately calls `unsetAgentWallet(agentId)`

That last step matters because ERC-8004 sets `agentWallet = msg.sender` during registration. Since `msg.sender` is the adapter, the adapter clears that default wallet immediately.

A convenience overload, `register(standard, boundAddress, tokenId, agentURI)`, registers with an empty metadata array.

The ownerless collection window is the same narrow authority used by unsigned counterfactual
writes: the collection must call the adapter directly for its own deployed address, and the window
closes once `ownerOf(tokenId)` returns a nonzero owner. A stranger cannot use it. Plain ERC-1155 and
ERC-6909 remain positive-balance controlled. After mint, the buyer (or an authorized delegate)
controls the bound ERC-8004 agent through the normal binding model; the collection has no special
authority unless it is itself the current controller.

For a full ERC-8004 identity created during mint, register before minting:

```solidity
function mint(address buyer, uint256 tokenId, string calldata agentURI) external {
    uint256 agentId = adapter.register(
        IERC8217.Standard.ERC721,
        address(this),
        tokenId,
        agentURI
    );
    _mint(buyer, tokenId);

    // The buyer's wallet separately opts into a reverse UBID claim; minting cannot make it for them.
}
```

The buyer's wallet can then call `setWalletUBID(standard, boundAddress, tokenId)` itself.
A smart wallet executes that call through its own authorization policy, so the adapter sees the
wallet address as `msg.sender`.

### 2b. There Is No Way To Bind An Existing Agent

Every agent under adapter management is minted by the adapter, in the same transaction that creates its
binding. There is no function that pulls an already-minted ERC-8004 identity into the adapter, and the
contract contains no ERC-721 transfer of any kind, in either direction. An agent that exists
independently stays independent.

This is deliberate. A binding is immutable and there is no unbind, revoke, withdraw or rescue path, so
binding an agent that already existed would irreversibly subordinate it: the adapter would own the NFT
permanently, control would follow the bound token so selling that token would hand over the agent, and
the reserved `agent-binding` metadata would be overwritten. `register` has none of that exposure,
because the agent it binds is born bound and nothing pre-existed to lose.

### Binding Metadata Format

On a successful `register`, the adapter writes canonical ERC-8217 metadata with:

- key: `agent-binding`
- value: `abi.encodePacked(address(this))`, the 20-byte adapter proxy address

The token coordinates are not stored in the metadata blob. A verifier reads the binding-contract address from the metadata and then reads the full binding from `bindingOf(agentId)` on that contract:

```solidity
struct Binding { Standard standard; address boundAddress; uint256 tokenId; }
```

Token standard enum values:

- `0x00`: `ERC721`
- `0x01`: `ERC1155`
- `0x02`: `ERC6909`
- `0x03`: `ERC1155F`
- `0x04`: `ERC6909F`
- `0x05`: `ACCOUNT` (an account-level binding of any address; always paired with `tokenId == 0`)
- `0x06`: `CONTRACT_OWNABLE` (dynamic current-`owner()` authority and its delegates, not the contract itself; always paired with `tokenId == 0`)
- `0x07`: `CONTRACT_ADMIN` (`DEFAULT_ADMIN_ROLE` authority, not the contract itself; always paired with `tokenId == 0`)

The enum is append-only: `ACCOUNT` remains `0x05`, `CONTRACT_OWNABLE` is appended as `0x06`, `CONTRACT_ADMIN` as `0x07`, and values `0x00`-`0x04` keep their meaning, so existing stored bindings and indexed history are unaffected. `0x05` also keeps its position; only its name and its code test changed, and neither is persisted.

The adapter reserves exactly one metadata key, `agent-binding`, and rejects caller attempts to set or batch-set it on either surface. It is reserved because the adapter writes that record itself, so an unreserved key would let a caller forge something the adapter authors. `cf-registration` was reserved until `0.0.17` and is now an ordinary key: nothing writes it, so there is no authored record to forge, and `bindingHashOf(agentId)` derives an agent's identifier rather than storing it, so it cannot be spoofed and is the authoritative source. Reserving one spelling would not have helped anyway, since a caller out to mislead an indexer can write `ubi` or any other suggestive name.

Note:

- `bindingContract` and `boundAddress` may be different addresses
- `bindingContract` and `boundAddress` may also be the same address if the token contract directly implements the binding logic

### Binding Verification

The ERC-facing verification flow is:

1. read the `agent-binding` metadata from the ERC-8004 record (20-byte binding-contract address)
2. call `bindingOf(agentId)` on that binding contract
3. decode `standard`, `boundAddress`, and `tokenId` from the returned struct
4. verify control against the bound token

That is the interoperable part.

This adapter also exposes `isController(agentId, account)` as a convenience view, but that function is adapter-specific and is not part of the ERC draft.

### 3. Manage The ERC-8004 Record

After registration, the current controller of the bound token can call the adapter to:

- `setAgentURI(agentId, newURI)`
- `setMetadata(agentId, key, value)`
- `setMetadataBatch(agentId, entries)`
- `setAgentWallet(agentId, newWallet, deadline, signature)`
- `unsetAgentWallet(agentId)`

The adapter checks control against the bound token and then forwards the call to ERC-8004.

### 4. Transfer Control

Control changes automatically when the external token changes hands.

Examples:

- ERC-721: if token `#1` is transferred, the new owner becomes controller
- ERC-1155: any holder with positive balance for the bound id is a controller
- ERC-6909: any holder with positive balance for the bound id is a controller
- ERC-1155F / ERC-6909F: if `ownerOf(tokenId)` changes, the new owner becomes controller

The ERC-8004 NFT itself is not transferred. It stays owned by the adapter.

### 5. Bind Or Clear The Agent Wallet

Wallet assignment still follows native ERC-8004 rules.

The adapter does not bypass ERC-8004 signature checks. To set a wallet, the controller calls:

```solidity
setAgentWallet(agentId, newWallet, deadline, signature)
```

ERC-8004 then requires proof from `newWallet`:

- EOA: valid EIP-712 signature
- smart wallet: valid ERC-1271 signature

Important detail:

- the typed-data `owner` field used by ERC-8004 is the current owner of the ERC-8004 token
- in this design, that owner is the adapter proxy address

So the signed payload must use:

- `owner = <adapter proxy address>`

not:

- `owner = <external token holder>`

### 6. Upgrade

The admin can upgrade the adapter implementation through UUPS. That is the whole escape hatch for
future ERC-8004 changes.

**The registry cannot be repointed.** It is fixed when the implementation is constructed, and
`_authorizeUpgrade` refuses any implementation carrying a different one, so upgrading is not a way
around it either. Repointing used to be available to the owner and was removed at `0.0.17` because
it allowed binding capture: agent ids are only meaningful inside the registry that issued them, so
pointing the adapter at a different registry made previously issued ids resolve to different agents.
Moving to a new ERC-8004 registry now means a new deployment, which is the honest cost.

## Counterfactual Registration

The counterfactual family mirrors the register surface as emit-only functions. They produce no ERC-8004 registry write and no adapter SSTORE; the emitted event is the only on-chain record. Every unsigned function shares the same token-authority rule as full `register`: existing current-controller authority, plus direct ERC-721/ERC-1155F/ERC-6909F collection authority for its own id while `ownerOf(tokenId)` reports no current owner. This temporary collection authority lets the complete identity record be emitted immediately before mint without an owner signature or staging transfer.

This enables off-chain identities: a token can carry a usable identity through events before any on-chain mint, and can later be promoted to a real on-chain registration.

Recommended collection flow:

```solidity
function mint(address buyer, uint256 tokenId, string calldata agentURI) external {
    adapter.counterfactualRegister(
        IERC8217.Standard.ERC721,
        address(this),
        tokenId,
        agentURI
    );
    // Optional URI, metadata, or wallet UBID setters may run here too.
    _mint(buyer, tokenId);
}
```

The collection must be the direct adapter caller and pass its own deployed address as `boundAddress`; a router, forwarded sender, `delegatecall`, or call from the collection constructor does not establish this authority. Register first and mint second. After `ownerOf` returns a nonzero owner, the collection has no special privilege and calls revert unless it separately qualifies under the normal owner/delegate controller model. The buyer or an authorized delegate can then overwrite the collection payload, and latest log order wins. Multiple emissions are allowed while no owner exists and share the same UBID.

`ACCOUNT` uses the same unsigned functions but a different authority: the bound address is the permanent sole controller at `tokenId 0`, so its counterfactual calls never stop working and never depend on an ownership probe. `CONTRACT_OWNABLE` also fixes `tokenId` at `0`, but accepts only the current canonical nonzero `owner()` and its delegates, not the bound contract; ownership transfers therefore change who may emit updates for existing claims. A failed or malformed `owner()` probe grants nobody authority, and there is no contract-self fallback. `CONTRACT_ADMIN` behaves the same way with `DEFAULT_ADMIN_ROLE` in place of `owner()`, so granting or revoking the role changes who may emit. There is no way to delete a counterfactual claim. A later authorized event supersedes an earlier one under the usual last-event-wins rule, and `counterfactualUnsetAgentWallet` clears only the wallet field, not the claim.

Plain ERC-1155 and ERC-6909 do not gain this ownerless path because neither standard supplies a universal global owner/nonexistence query; their unsigned calls still require positive balance. A reverted `ownerOf` or canonical `address(0)` response means “no current owner,” not “never minted,” so burning a single-owner id can reopen the collection-only window. Signature-based counterfactual registration is intentionally not supported: register-at-mint collections should call the unsigned function directly while the id is ownerless, then mint.

Functions:

- `counterfactualRegister(standard, boundAddress, tokenId, agentURI, metadata)` and the empty-metadata overload `counterfactualRegister(standard, boundAddress, tokenId, agentURI)`
- `counterfactualSetAgentURI(standard, boundAddress, tokenId, newURI) -> bytes32`
- `counterfactualSetMetadata(standard, boundAddress, tokenId, key, value) -> bytes32`
- `counterfactualSetMetadataBatch(standard, boundAddress, tokenId, entries) -> bytes32`
- `counterfactualSetAgentWallet(standard, boundAddress, tokenId, newWallet) -> bytes32` (no signature because no ERC-8004 wallet binding is created)
- `counterfactualUnsetAgentWallet(standard, boundAddress, tokenId) -> bytes32`
- `hashBinding(standard, boundAddress, tokenId)` (view)
- `bindingHashOf(agentId)` (view) returns the same identity for an agent registered through this
  adapter, derived from its stored binding, and reverts `UnknownAgent` for an id that was never
  registered
- `interoperableAddress(account)` (view)
- `chainIdentifier()` (view)

Indexer rules:

- each event carries the `uint8 standard` as its first non-indexed field. Carrying the standard on every event is what makes a single log line verifiable against the hash it names, with no lookup. There is no in-payload schema version and no reserved discriminator: `topic0` is the keccak of the full event signature, so it already discriminates schema on its own
- the three indexed topics are fixed across every event: `(ubi, boundAddress, tokenId)`
- the UBID is
  `keccak256(abi.encode(interoperableAddress(adapterProxy), standard, boundAddress, tokenId))`,
  using standard `(bytes,uint8,address,uint256)` ABI encoding (not packed); the adapter proxy
  carries the full local ERC-7930 envelope, `boundAddress` remains a naked EVM address, and
  `standard` is the `Standard` enum's `uint8`. Those four components are the adapter address
  plus exactly the stored `Binding`, so nothing in the preimage is unavailable from `bindingOf`
- `interoperableAddress(account)` is the ERC-7930 v1 / CAIP-350 `eip155` encoding of the local
  chain plus AddressLength `20` and the raw EVM address
- **the adapter does not implement that encoding itself.** Since `0.0.17` it calls OpenZeppelin's
  `InteroperableAddress.formatEvmV1`. The values are unchanged — every published vector still holds
  byte for byte — but anyone forking this contract, or bumping the OpenZeppelin submodule, should
  know that the library's file is `draft-` prefixed and therefore carries no encoding stability
  guarantee across releases. Since this encoding is the preimage of every UBID and
  every `attestationId`, a change to it would re-key every identity silently. `test/Adapter8004.erc7930-frozen.t.sol`
  exists to turn that into an immediate test failure; the two former in-house encoders are kept
  frozen there as independent oracles and must not be deleted
- `chainIdentifier()` returns the same local chain envelope with AddressLength `0`; it remains a
  useful chain diagnostic but is not one of the canonical hash fields
- chain binding comes from the adapter proxy's Interoperable Address alone; do not encode
  `boundAddress` as an Interoperable Address
- indexers MUST treat the latest event per UBID as authoritative, latest meaning
  highest block number, then highest log index
- a later full registration replaces the earlier full payload and later setters update individual
  fields
- ownerless collection events carry `emitter == boundAddress`; this records the authorizing caller,
  but is not a permanent proof that the token was pre-mint because the collection may later be a
  normal owner or delegate
- the token standard is **part of** the UBID, so two standards claiming the same
  `(boundAddress, tokenId)` are two identities and never alias. The worked example is a contract at
  `(X, 0)` that claims as ERC-721 token `#0`, `ACCOUNT`, and `CONTRACT_OWNABLE`: three coordinates,
  three distinct hashes, three separate histories. Last-event-wins therefore resolves within one
  standard only, and no claimant's history can be superseded by, or attributed to, a claimant who
  reached the same pair through a different authority route
- what the standard in the hash records is that the claimer passed *that standard's* authority probe
  at claim time. It is **not** an assertion that the bound contract conforms to the ERC; the adapter
  probes authority and never calls `supportsInterface`
- because the enum's `uint8` is in the preimage, `Standard` numbering is identity-critical.
  Append only: never renumber, never reorder, never remove a member
- the standard is a non-indexed body field on every counterfactual event, so it cannot be filtered by
  topic — filter by the UBID instead, which already distinguishes standards. The on-chain
  `AgentBound.standard` is indexed and unchanged

Every counterfactual function that derives an identity returns it as `bytes32`, so a caller never recomputes the hash or reads it back out of the log. The value is the same one `hashBinding` returns and the same one the emitted event carries.

Reserved key on the counterfactual write surface: `agent-binding`, and nothing else.

> BREAKING-CHANGE WARNING. Adding, removing, or reordering any field in a counterfactual event changes the event signature, which changes the `keccak256` topic. Indexers watching the old topic stop receiving events on the upgraded implementation. Treat any change to these event ABIs as a hard cutover: bump the implementation, document the cutover block, and require every downstream indexer to subscribe to the new topics from that block forward.

### Wallet UBID self-claims

A wallet points at one UBID to speak for it. The pointer is needed because `wallet -> agent` is one to many: ERC-8004's `setAgentWallet` makes every agent prove the wallet consented, so many agents can validly list one wallet and the reverse direction is ambiguous. This mapping is how the wallet chooses. It is an account assertion, not proof: consumers must also verify the corresponding counterfactual wallet event.

- `setWalletUBID(standard, boundAddress, tokenId)` records a claim for `msg.sender`
- `clearWalletUBID()` clears only `msg.sender`'s claim
- `counterfactualSetAgentWalletAndUBID(standard, boundAddress, tokenId) -> bytes32` names the caller
  as the wallet and points that wallet back at the identity in one call, returning the identity it
  derived. No signature is needed because the caller proves control of the token and is the wallet,
  so one actor is authorized on both sides and two agreeing records mean something. Naming a
  different wallet requires the identity controller to call `counterfactualSetAgentWallet` and
  that wallet to separately call `setWalletUBID` for itself
- setters derive the hash; callers cannot supply an arbitrary UBID
- designation is emit-only: indexers apply `WalletUBIDSet` / `WalletUBIDCleared` in log order;
  there is no on-chain getter or unset sentinel

**There was a second pointer, wallet to agent id, until `0.0.17`.** It is gone and should not come
back. An agent id is meaningful only inside the registry that issued it, so a reverse-resolution
surface keyed on agent ids had the contract contradicting ERC-8217. Nothing reconciled the two
pointers either: a wallet could aim them at unrelated things and no rule said which a consumer
should believe. The agent-id half was also the less checkable, returning a bare number no consumer
could verify without already knowing the registry, while the adapter had verified nothing. What is
genuinely lost is a wallet designating an ERC-8004 agent never bound through this adapter, which is
out of scope: the adapter can say nothing about such an agent.

Only the immediate caller may set or clear its reverse claim. `setWalletUBIDFor` and
`clearWalletUBIDFor` have been removed, together with the owner/getOwner/admin inference helper.
For an EOA, the wallet sends the transaction. For a smart wallet, its owners/signers authorize the
wallet to execute the adapter call using the wallet's own rules. An owner, admin, delegate, or relayer
calling the adapter directly can claim only for its own address, never for another wallet.
The existing event layouts are unchanged: `account` and `setBy` / `clearedBy` now always equal
`msg.sender`. This does not change the separate authorization rules for managing a bound identity.
The signed, relayer-submittable variant was also removed earlier in `0.0.17` before deployment.

This is a hard cutover from unreleased source behavior, not a production storage migration. Neither pointer was ever deployed and the surviving one stores nothing at all, so regular storage is slot 1 alone; slot 0 is the one reserved dead slot, because it is the only one that physically holds data on a live proxy. Old bare-chain-id hashes are invalid. See the [hash vectors](./docs/fixtures/adapter-counterfactual-hashes.md) and the [indexer cutover guide](./docs/adapter-v014-indexer-migration.md).

## Counterfactual Attestations

Counterfactual identities cost nothing to create, but until now nothing could say anything about one. ERC-8004's reputation registry only accepts feedback on registered agents, so an agent's whole pre-registration track record was unrecordable, and ERC-8048's additional-account list is one-directional, so a listed account could neither confirm nor refuse the listing. This surface closes both.

An attestation is a public statement about a `ubi`, recorded in the event log. Its meaning rests entirely on who made it, and **who made it is always the caller**.

- `attest(AttestationType attestationType, bytes32 ubi, bytes32 variant, bytes data)`
- `confirmAdditionalAccount(bytes32 ubi)` — exactly `attest(AttestationType.CONFIRM_ACCOUNT, ubi, 0, "")`
- `revoke(bytes32 attestationId)`

Events: `Attested(address indexed attester, AttestationType indexed attestationType, bytes32 indexed ubi, bytes32 attestationId, bytes32 variant, bytes data)` and `AttestationRevoked(bytes32 indexed attestationId, address indexed revoker)`. The three indexed slots on `Attested` are the three canonical query axes: reverse by attester, forward by target, filter by type.

The identifier, emitted so nobody has to recompute it:

```text
keccak256(abi.encode(adapterInteroperableAddress, attester, ubi, attestationType, block.number, variant, data))
```

`attestationType` enters as the enum's `uint8`, right-aligned in a word, which is what `abi.encode` of a Solidity enum produces.

- `block.number` bounds a revocation to one block. Without it, an attester emitting byte-identical statements over time — a monitor issuing repeated pings — would collapse its whole history into one identifier that a single revocation erases.
- `variant` is the caller's opt-in within-block distinguisher, zero when unused. Cross-block distinction is automatic; within-block distinction is asked for.
- There is **no domain constant**. Nothing here is signed, and the interoperable address already binds the preimage to this adapter on this chain. The two derivation schemes cannot collide: for one adapter the counterfactual preimage is a fixed 224 bytes and this one is at least 320.

**The caller is the attester, and there is no acting-for path.** A controller participates by causing the account itself to make the call, so the account is still `msg.sender`; nothing can manufacture an account's consent from outside it. The cost is chosen: an account that cannot make outbound calls, such as a minimal vault or a payment splitter with no executor, cannot attest. Ordinary wallets, multisigs, smart wallets with executors, timelocks, and EIP-7702-delegated accounts all can.

**Five types, in a closed `AttestationType` enum.** The set is fixed by the deployed implementation, so admitting a sixth is an upgrade. That is a deliberate choice of a closed namespace over an open one: a type is what an enum is for, `Standard` in the same contract is already an enum, and the contract is upgradeable, so the cost of admitting a type is an upgrade the owner can already make.

| Member | `uint8` | Payload | Projection |
|---|---|---|---|
| `UNSPECIFIED` | `0` | reserved sentinel, never a real type | — |
| `CONFIRM_ACCOUNT` | `1` | empty | state |
| `STAR` | `2` | one byte, `0` or `1` | state |
| `RATING` | `3` | one byte, `0`–`100`, on ERC-8004's `starred` scale | state |
| `REVIEW` | `4` | UTF-8 text, non-empty | stream |
| `INTERACTION` | `5` | `uint8 score \|\| bytes32 reference \|\| bytes text`, at least 33 bytes | stream |

`UNSPECIFIED` holds zero because Solidity enums start there: without it the first real type would be the value a default-initialized variable carries, which is exactly what `AttestationTypeZero` exists to reject.

The numbering is identity-critical, exactly as the `Standard` numbering is: the `uint8` sits in the identifier preimage, so renumbering a member re-keys every attestation ever emitted under it. Append only, never reorder.

One thing the enum buys: the ABI decoder rejects a value above the last member before any contract code runs, so a garbage type is refused for free rather than by a check.

**What the contract enforces is exactly two things**: `attestationType != UNSPECIFIED` and `ubi != 0` on the two attest paths. Both are sentinel rules against default-initialized calldata, not validation. A nonzero garbage `ubi` passes on purpose — counterfactual registration writes no storage, so no set of real hashes exists to check against, and attesting ahead of an identity's first claim is the supported case. `revoke` checks nothing at all, the zero identifier included, because revoking a statement never made is a recorded no-op for readers.

Everything else is the reader's: target resolution, payload well-formedness, whether a revocation counts at all (only from the original attester, which an emit-only contract cannot check), and reviewer independence from the subject. The projection rules, payload encodings, and full type registry are normative in [the type-registry specification](./docs/specs/attestation-type-registry-v1.md), with identifier vectors in [the attestation fixture](./docs/fixtures/adapter-attestation-ids.md).

**Emit-only, with two consequences.** No contract can read attestations on chain. Nothing needs to today, and a stored system can be added later if that changes. The surface also adds no storage slot, so regular storage still ends at slot 1. These functions also carry no `nonReentrant`, unlike the counterfactual writers: they make no external call, so the guard would cost roughly 2,900 gas per call to protect against nothing. That is a decision, and a test fails if the modifier is ever added back.

Execution gas measured in the assembled contract, excluding the fixed 21,000 per transaction: `attest` with a small payload 7,581, `confirmAdditionalAccount` 6,916, `revoke` 1,889, plus roughly 9 gas per payload byte. `revoke` is much the cheapest because it derives no identifier at all. The other two are dominated by the ERC-7930 envelope every identity derivation builds, which every counterfactual write pays too, since they share the helper.

**Joining to a registration.** For any adapter-registered agent the two histories merge with no transaction and no link assertion: `bindingOf(agentId)` yields the standard, bound address and token id from which the agent's counterfactual-era UBID derives. A registration joins only the counterfactual history claimed under its own standard, which is one of the reasons the standard is in the identifier.

## ERC Alignment

This repo targets the agent-binding discovery format defined by [ERC-8217: Agent NFT Identity Bindings](https://eips.ethereum.org/EIPS/eip-8217). ERC-8217 has been merged into Ethereum/ERCs (originally PR [#1648](https://github.com/ethereum/ERCs/pull/1648)) but is still a Draft, not a finalized standard, so the format may change before the ERC is finalized.

The README and contract align on the following points:

- reserved metadata key: `agent-binding`
- metadata value: the 20-byte binding-contract address, `abi.encodePacked(address(this))`
- token coordinates resolved from `bindingOf(agentId)` on the binding contract
- token standard enum values: `0x00` = `ERC721`, `0x01` = `ERC1155`, `0x02` = `ERC6909`, `0x03` = `ERC1155F`, `0x04` = `ERC6909F`, `0x05` = `ACCOUNT`, `0x06` = `CONTRACT_OWNABLE`, `0x07` = `CONTRACT_ADMIN`
- required verification surface: `bindingOf(uint256 agentId)`

The adapter intentionally goes beyond the ERC draft by also exposing:

- `register(...)`
- `setAgentURI(...)`
- `setMetadata(...)`
- `setMetadataBatch(...)`
- `setAgentWallet(...)`
- `unsetAgentWallet(...)`
- `isController(...)`
- the counterfactual register family

## Admin Model

The adapter owner can:

- upgrade the adapter implementation, to an implementation carrying the same `identityRegistry`
- transfer adapter ownership to a new admin

That is the whole owner surface. **No owner function reaches into an individual agent's state.** The owner cannot rewrite a binding, cannot rewrite an agent's metadata, cannot move an agent, and cannot act as a controller for one. The owner also cannot change `identityRegistry`: it is `immutable`, there is no setter, and the upgrade path checks it.

## Contract Surface

User-facing functions:

- `register(Standard standard, address boundAddress, uint256 tokenId, string agentURI, MetadataEntry[] metadata)`
- `register(Standard standard, address boundAddress, uint256 tokenId, string agentURI)`
- `setAgentURI(uint256 agentId, string newURI)`
- `setMetadata(uint256 agentId, string metadataKey, bytes metadataValue)`
- `setMetadataBatch(uint256 agentId, MetadataEntry[] metadata)`
- `setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes signature)`
- `unsetAgentWallet(uint256 agentId)`
- `bindingOf(uint256 agentId)`
- `isController(uint256 agentId, address account)`
- `getMetadata(uint256 agentId, string metadataKey)`
- `getAgentWallet(uint256 agentId)`
- `ownerOf(uint256 agentId)`
- `tokenURI(uint256 agentId)`

Attestation (emit-only) functions:

- `attest(AttestationType attestationType, bytes32 ubi, bytes32 variant, bytes data)`
- `confirmAdditionalAccount(bytes32 ubi)`
- `revoke(bytes32 attestationId)`

Counterfactual (emit-only) functions:

- `counterfactualRegister(Standard standard, address boundAddress, uint256 tokenId, string agentURI, MetadataEntry[] metadata)`
- `counterfactualRegister(Standard standard, address boundAddress, uint256 tokenId, string agentURI)`
- `counterfactualSetAgentURI(Standard standard, address boundAddress, uint256 tokenId, string newURI) -> bytes32`
- `counterfactualSetMetadata(Standard standard, address boundAddress, uint256 tokenId, string metadataKey, bytes metadataValue) -> bytes32`
- `counterfactualSetMetadataBatch(Standard standard, address boundAddress, uint256 tokenId, MetadataEntry[] metadata) -> bytes32`
- `counterfactualSetAgentWallet(Standard standard, address boundAddress, uint256 tokenId, address newWallet) -> bytes32`
- `counterfactualUnsetAgentWallet(Standard standard, address boundAddress, uint256 tokenId) -> bytes32`
- `hashBinding(Standard standard, address boundAddress, uint256 tokenId)`
- `bindingHashOf(uint256 agentId)`
- `interoperableAddress(address account)`
- `chainIdentifier()`
- `setWalletUBID(Standard standard, address boundAddress, uint256 tokenId)`
- `clearWalletUBID()`

ERC-required verification function:

- `bindingOf(uint256 agentId)`

Adapter-specific convenience function:

- `isController(uint256 agentId, address account)`

Admin-facing functions:

- `initialize(address initialOwner)`
- `upgradeToAndCall(address newImplementation, bytes data)`

`identityRegistry()` is a view over an `immutable` set in the constructor. There is no setter.

## Build And Test

```sh
forge build
forge test
forge fmt
```

## Deploy

Copy `.env.example` to `.env` and fill in the values:

```sh
cp .env.example .env
# edit .env
```

Required environment variables:

- `DEPLOYER_PRIVATE_KEY`
- `BASE_RPC_URL`
- `MAINNET_RPC_URL`
- `SEPOLIA_RPC_URL`
- `BASE_IDENTITY_REGISTRY_ADDRESS`
- `MAINNET_IDENTITY_REGISTRY_ADDRESS`
- `SEPOLIA_IDENTITY_REGISTRY_ADDRESS`

The deployer becomes the adapter admin automatically.

Deploy to Base:

```sh
script/deploy.sh base
```

Deploy to Ethereum mainnet:

```sh
script/deploy.sh mainnet
```

Deploy to Sepolia:

```sh
script/deploy.sh sepolia
```

## Test Coverage

The Foundry suite currently covers:

- registration for ERC-721, ERC-1155, ERC-6909, ERC-1155F, and ERC-6909F bindings
- account bindings (`ACCOUNT`), for a non-token binder, an ERC-20 fixture, and a code-less address:
  bound-address-only authority, acceptance of an address with no runtime code on every entry path,
  identical behavior with and without an EIP-7702 designator, denial of every delegate.xyz delegation
  shape, rejection of the zero address at every entry point, the `tokenId == 0` rule at every write
  entry point, absence of any `ownerOf` / `balanceOf` probe, the `(X, 0)` per-standard identity
  separation, and raw `AgentBound` / `CounterfactualAgentRegistered` layout compatibility
- constructor-time binding: a contract binding itself as `ACCOUNT` from its own constructor on both the
  on-chain and counterfactual paths, staying sole controller once code exists, contrasted with all seven
  code-requiring standards still rejecting the same call
- opt-in ownable contract bindings (`CONTRACT_OWNABLE`): dynamic owner authority, not contract-self
  ownership transfer, fail-closed reverting/malformed/zero `owner()` responses, holder/admin/stranger
  denial, the canonical `tokenId == 0` rule at both authority choke points, enum stability, and raw
  event-layout compatibility for value `6`
- opt-in admin contract bindings (`CONTRACT_ADMIN`): `DEFAULT_ADMIN_ROLE` authority, denial of the
  bound contract and of non-admins, live revocation, fail-closed missing and non-canonical `hasRole`
  responses, absence of a delegate.xyz route, and the canonical `tokenId == 0` rule at both authority
  choke points
- delegate.xyz v2 hot/cold control for ERC-721, ERC-1155F, and ERC-6909F bindings
- immutable per-agent bindings
- repeated registration using the same external token
- control transfer after external token transfers
- metadata and URI updates
- wallet-binding pass-through with valid and invalid ERC-8004 signatures, which is the registry's
  own EIP-712 surface and is unaffected by the adapter dropping its own
- the signed primary-agent surface staying removed: each removed selector probed and required not to
  resolve, neither `WithSig` event topic emitted, and nothing written past the last declared slot
- the counterfactual register family, including reserved-key rejection and the event body shape
- the ERC-7930 encoding, which production now takes from OpenZeppelin's `draft-InteroperableAddress`,
  pinned against three independent oracles: the two former in-house encoders kept frozen as
  `ReferenceErc7930` and `WordAlignedErc7930`, exact bytes for twelve chain ids on both shapes, and
  the ERC-7930 spec's own reference examples. Three-way agreement is fuzzed across all 32 reference
  lengths on both shapes, round-tripped through `parseEvmV1`, and asserted end to end through
  the UBID, the attestation identifier and a real counterfactual emission. Because the
  library is `draft-` prefixed and owes no encoding stability, one test exists solely to fail loudly
  if a submodule bump changes the output
- the attestation surface: the identifier pinned against precomputed vectors rather than round trips,
  the `AttestationType` enum numbering pinned member by member, out-of-range types refused by the ABI
  decoder rather than by a guard,
  binding to the proxy and not the implementation, the negative-encoding matrix, both guards with a
  test that fails if either check is deleted, `confirmAdditionalAccount` emitting a byte-identical
  event to the equivalent `attest` call, zero `SSTORE`s captured with `vm.record`, the deliberate
  absence of `nonReentrant` pinned by forcing the guard slot to `ENTERED`, the code-size margin floor,
  and measured gas for all three functions
- a projection harness that replays the published reader rules over real logs: collapse, withdrawal,
  reactivation within and across blocks, state resurrection, non-attester revocations ignored, unstar
  versus revoke, and the per-type payload rules the contract never decodes
- proxy initialization
- admin-only registry repointing
- admin-only implementation upgrades

Tests:

- [`test/Adapter8004.t.sol`](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol)
