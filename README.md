# ERC-8004 Identity Adapter

## Version `0.0.14`

![version](https://img.shields.io/badge/version-0.0.14-blue)

The current contract version is **`0.0.14`** (`@custom:version` in [`src/Adapter8004.sol`](./src/Adapter8004.sol)). This is unreleased repo source and is not yet live on-chain (see [Deployments](#deployments)).

---

This project lets an external token control an ERC-8004 `IdentityRegistry` record while the adapter proxy remains the on-chain owner of the ERC-8004 identity token.

## How It Works

Registration flow:

```text
  ┌──────────────┐
  │ Token holder │
  └──────────────┘
         │
         │ register(standard, tokenContract, tokenId, agentURI)
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

What the unreleased source adds over the active deployments (on-chain status varies by chain — see [CHANGELOG.md](./CHANGELOG.md): the counterfactual register family is live on all three proxies, delegate.xyz support is live on Sepolia only, and `bindExisting` and the primary-agent surface are not yet deployed anywhere):

- `bindExisting(...)`: pull an already-minted ERC-8004 agent into adapter management against an external token, using a two-transaction approval model.
- delegate.xyz v2 hot/cold control for single-owner bindings: a delegated hot wallet can drive an ERC-721-, ERC-1155F-, or ERC-6909F-bound agent while the token stays in cold storage.
- A counterfactual register family: emit-only mirrors of the register surface that produce no registry write and no SSTORE, for off-chain identities that can later be promoted on-chain.
- Direct collection register-at-mint for ownerless ERC-721/ERC-1155F/ERC-6909F ids through the existing unsigned counterfactual selectors.
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
- [`src/interfaces/IERCAgentBindings.sol`](/Users/nxt3d/projects/adapter/src/interfaces/IERCAgentBindings.sol)
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

The unreleased `0.0.14` implementation upgrades directly from the active
Mainnet/Base May 15 build or the active Sepolia delegate.xyz build—not from
unreleased numbered source versions. Both live layouts populate only regular
slots 0 and 1. The three new primary-agent mappings append directly at slots
2-4. Existing proxies must use empty
`upgradeToAndCall` data; `initialize(...)` is only for a new proxy. No storage
migration or reinitializer is required. Sepolia's delegate.xyz getters and
authorization remain present in `0.0.14`.

## Flow

### 1. Deploy

You deploy:

- an adapter implementation
- an `ERC1967Proxy`
- the proxy is initialized with:
  - `identityRegistry`
  - `initialOwner` / admin

After deployment:

- users interact with the proxy address
- the admin can upgrade the adapter
- the admin can update the `identityRegistry` address if ERC-8004 migrates

### 2. Register A Bound Agent

A current controller, or a supported single-owner collection registering before mint, calls:

```solidity
register(standard, tokenContract, tokenId, agentURI, metadata)
```

The adapter does this:

1. verifies the caller currently controls the external token, or that the direct caller is the
   ERC-721/ERC-1155F/ERC-6909F `tokenContract` and `ownerOf(tokenId)` reports no current owner
2. rejects user metadata that tries to overwrite the canonical binding record
3. calls `identityRegistry.register(...)`
4. becomes owner of the new ERC-8004 identity token
5. stores the immutable binding on that `agentId`
6. writes canonical binding metadata under `agent-binding` (the 20-byte adapter proxy address)
7. immediately calls `unsetAgentWallet(agentId)`

That last step matters because ERC-8004 sets `agentWallet = msg.sender` during registration. Since `msg.sender` is the adapter, the adapter clears that default wallet immediately.

A convenience overload, `register(standard, tokenContract, tokenId, agentURI)`, registers with an empty metadata array.

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
        IERCAgentBindings.TokenStandard.ERC721,
        address(this),
        tokenId,
        agentURI
    );
    _mint(buyer, tokenId);

    // Optional: when this caller is authorized for `buyer` under the primary-agent account-control
    // model, associate the freshly registered full identity with the buyer.
    adapter.setPrimaryAgentFor(buyer, agentId);
}
```

If the collection cannot authorize `setPrimaryAgentFor(buyer, agentId)`, the buyer can set the
pointer separately with `setPrimaryAgent(agentId)` (or use the signed full-primary path).
`registerAndSetPrimary` remains caller-scoped: an ownerless collection using it sets the collection's
own primary, not the future buyer's. `bindExisting` does not receive ownerless collection authority;
it continues to require ordinary current control of an already-existing external token.

### 2b. Bind An Existing Agent

`bindExisting` pulls an already-minted ERC-8004 `agentId` into adapter management against an external token. It is a two-transaction flow:

1. the agent owner approves the adapter on the ERC-8004 registry: `approve(adapter, agentId)` or `setApprovalForAll(adapter, true)`
2. the same owner calls:

```solidity
bindExisting(agentId, standard, tokenContract, tokenId)
```

The adapter does this:

1. rejects an invalid token contract, and the registry itself, the same way `register` does
2. rejects an already-bound agent so adapter bindings stay immutable
3. requires the caller to own the agent in the ERC-8004 registry
4. requires the caller to control the external token under the binding-control model (direct ownership, or delegate.xyz for ERC-721/ERC-1155F/ERC-6909F)
5. requires prior ERC-721 transfer approval for `agentId`
6. transfers the ERC-8004 identity into the adapter
7. stores the immutable binding
8. overwrites the reserved `agent-binding` metadata key to point at this adapter
9. emits `AgentBound`

The pre-existing `agentURI` and all non-binding metadata are preserved. Only the reserved `agent-binding` key is overwritten. Unlike `register`, `bindExisting` does not clear the agent wallet, because transferring an existing identity does not reset its wallet to the adapter.

### Binding Metadata Format

On a successful `register` or `bindExisting`, the adapter writes canonical ERC-8217 metadata with:

- key: `agent-binding`
- value: `abi.encodePacked(address(this))`, the 20-byte adapter proxy address

The token coordinates are not stored in the metadata blob. A verifier reads the binding-contract address from the metadata and then reads the full binding from `bindingOf(agentId)` on that contract:

```solidity
struct Binding { TokenStandard standard; address tokenContract; uint256 tokenId; }
```

Token standard enum values:

- `0x00`: `ERC721`
- `0x01`: `ERC1155`
- `0x02`: `ERC6909`
- `0x03`: `ERC1155F`
- `0x04`: `ERC6909F`

The adapter reserves the `agent-binding` key and rejects user attempts to set or batch-set it through the adapter. The `cf-registration` (canonical-promotion) key is reserved on both surfaces: every counterfactual write rejects it, and the canonical writes (`register`, `setMetadata`, `setMetadataBatch`) reject it too, so a controller cannot fabricate a promotion back-link on either surface before a genuine on-chain mint.

Note:

- `bindingContract` and `tokenContract` may be different addresses
- `bindingContract` and `tokenContract` may also be the same address if the token contract directly implements the binding logic

### Binding Verification

The ERC-facing verification flow is:

1. read the `agent-binding` metadata from the ERC-8004 record (20-byte binding-contract address)
2. call `bindingOf(agentId)` on that binding contract
3. decode `standard`, `tokenContract`, and `tokenId` from the returned struct
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

### 6. Upgrade Or Repoint

The admin can:

- upgrade the adapter implementation through UUPS
- update `identityRegistry` to a new ERC-8004 registry address

This is the escape hatch for future ERC-8004 changes.

Note that repointing only changes where future forwarded calls go. It does not migrate already-created ERC-8004 identities out of an old registry.

## Counterfactual Registration

The counterfactual family mirrors the register surface as emit-only functions. They produce no ERC-8004 registry write and no adapter SSTORE; the emitted event is the only on-chain record. Every unsigned function shares the same token-authority rule as full `register`: existing current-controller authority, plus direct ERC-721/ERC-1155F/ERC-6909F collection authority for its own id while `ownerOf(tokenId)` reports no current owner. This temporary collection authority lets the complete identity record be emitted immediately before mint without an owner signature or staging transfer.

This enables off-chain identities: a token can carry a usable identity through events before any on-chain mint, and can later be promoted to a real on-chain registration.

Recommended collection flow:

```solidity
function mint(address buyer, uint256 tokenId, string calldata agentURI) external {
    adapter.counterfactualRegister(
        IERCAgentBindings.TokenStandard.ERC721,
        address(this),
        tokenId,
        agentURI
    );
    // Optional URI, metadata, or wallet counterfactual setters may run here too.
    _mint(buyer, tokenId);
}
```

The collection must be the direct adapter caller and pass its own deployed address as `tokenContract`; a router, forwarded sender, `delegatecall`, or call from the collection constructor does not establish this authority. Register first and mint second. After `ownerOf` returns a nonzero owner, the collection has no special privilege and calls revert unless it separately qualifies under the normal owner/delegate controller model. The buyer or an authorized delegate can then overwrite the collection payload, and latest log order wins. Multiple emissions are allowed while no owner exists and share the same `registrationHash`.

Plain ERC-1155 and ERC-6909 do not gain this ownerless path because neither standard supplies a universal global owner/nonexistence query; their unsigned calls still require positive balance. A reverted `ownerOf` or canonical `address(0)` response means “no current owner,” not “never minted,” so burning a single-owner id can reopen the collection-only window. Signature-based counterfactual registration is intentionally not supported: register-at-mint collections should call the unsigned function directly while the id is ownerless, then mint.

Functions:

- `counterfactualRegister(standard, tokenContract, tokenId, agentURI, metadata)` and the empty-metadata overload `counterfactualRegister(standard, tokenContract, tokenId, agentURI)`
- `counterfactualSetAgentURI(standard, tokenContract, tokenId, newURI)`
- `counterfactualSetMetadata(standard, tokenContract, tokenId, key, value)`
- `counterfactualSetMetadataBatch(standard, tokenContract, tokenId, entries)`
- `counterfactualSetAgentWallet(standard, tokenContract, tokenId, newWallet)` (no signature because no ERC-8004 wallet binding is created)
- `counterfactualUnsetAgentWallet(standard, tokenContract, tokenId)`
- `registrationHash(tokenContract, tokenId)` (view)
- `interoperableAddress(account)` (view)
- `chainIdentifier()` (view)

Indexer rules:

- each event carries `bytes32 extraData` as its first non-indexed field; this baseline emits `bytes32(0)`. There is no in-payload schema version: `topic0` is the keccak of the full event signature, so it already discriminates schema on its own
- the three indexed topics are fixed across every event: `(registrationHash, tokenContract, tokenId)`
- the `registrationHash` is
  `keccak256(abi.encode(interoperableAddress(adapterProxy), tokenContract, tokenId))`,
  using standard `(bytes,address,uint256)` ABI encoding (not packed); the adapter proxy carries the
  full local ERC-7930 envelope, `tokenContract` remains a naked EVM address, and the token standard
  remains excluded
- `interoperableAddress(account)` is the ERC-7930 v1 / CAIP-350 `eip155` encoding of the local
  chain plus AddressLength `20` and the raw EVM address
- `chainIdentifier()` returns the same local chain envelope with AddressLength `0`; it remains a
  useful chain diagnostic but is not one of the canonical hash fields
- chain binding comes from the adapter proxy's Interoperable Address alone; do not encode
  `tokenContract` as an Interoperable Address
- indexers MUST treat the latest event per `(tokenContract, tokenId)` as authoritative
- order state transitions by `(blockNumber, transactionIndex, logIndex)`; a later full registration
  replaces the earlier full payload and later setters update individual fields
- ownerless collection events carry `emitter == tokenContract`; this records the authorizing caller,
  but is not a permanent proof that the token was pre-mint because the collection may later be a
  normal owner or delegate

Reserved keys on the counterfactual write surface: `agent-binding` and `cf-registration`.

> BREAKING-CHANGE WARNING. Adding, removing, or reordering any field in a counterfactual event changes the event signature, which changes the `keccak256` topic. Indexers watching the old topic stop receiving events on the upgraded implementation. Treat any change to these event ABIs as a hard cutover: bump the implementation, document the cutover block, and require every downstream indexer to subscribe to the new topics from that block forward.

### Independent primary-agent systems

`0.0.14` has two structurally separate reverse claims. Full ERC-8004 uses `address => uint256 agentId`; counterfactual uses `address => bytes32 registrationHash`. An account can hold both, and a write in one system cannot affect the other. Both are account assertions, not proof: consumers must also verify the corresponding registry `agentWallet` or counterfactual wallet event.

Full ERC-8004:

- `setPrimaryAgent(uint256 agentId)` / `setPrimaryAgentFor(account, agentId)`
- `clearPrimaryAgent()` / `clearPrimaryAgentFor(account)`
- `primaryAgentOf(account) -> uint256`
- `setPrimaryAgentWithSig(...)`, `clearPrimaryAgentWithSig(...)`, and `primaryAgentNonces(account)`
- unset is `PRIMARY_AGENT_UNSET == type(uint256).max`; agent ID `0` is valid

Counterfactual:

- `setPrimaryCounterfactualAgent(tokenContract, tokenId)` / `setPrimaryCounterfactualAgentFor(account, tokenContract, tokenId)`
- `clearPrimaryCounterfactualAgent()` / `clearPrimaryCounterfactualAgentFor(account)`
- `primaryCounterfactualAgentOf(account) -> bytes32`
- setters derive the hash; callers cannot store an arbitrary value
- unset is `PRIMARY_COUNTERFACTUAL_AGENT_UNSET == bytes32(type(uint256).max)`

Paid `...For` authorization is identical for both systems: account self, `owner()` / `getOwner()`, or `DEFAULT_ADMIN_ROLE`. The full-system signed reverse-pointer calls are strictly account-self through EOA/ERC-1271 `SignatureChecker`, allow any relayer, and retain the inclusive 30-minute deadline cap. Counterfactual primaries intentionally have no signed/gasless surface; collections use the direct unsigned register-at-mint path and `setPrimaryCounterfactualAgentFor`. `registerAndSetPrimary` writes only the full mapping.

Each full-system signed reverse-pointer path emits its state event first and its `WithSig` provenance event second.

This is a hard cutover from unreleased source behavior, not a production storage migration. Live proxies never deployed the old mixed pointer or shared nonce, so the new mappings occupy slots 2–4 and start empty. Old bare-chain-id hashes and old EIP-712 signatures are invalid. See the [full signed-primary fixture](./docs/fixtures/adapter-primaryagent-withsig.md), [hash vectors](./docs/fixtures/adapter-counterfactual-hashes.md), and [indexer cutover guide](./docs/adapter-v014-indexer-migration.md).

## ERC Alignment

This repo targets the agent-binding discovery format defined by [ERC-8217: Agent NFT Identity Bindings](https://eips.ethereum.org/EIPS/eip-8217). ERC-8217 has been merged into Ethereum/ERCs (originally PR [#1648](https://github.com/ethereum/ERCs/pull/1648)) but is still a Draft, not a finalized standard, so the format may change before the ERC is finalized.

The README and contract align on the following points:

- reserved metadata key: `agent-binding`
- metadata value: the 20-byte binding-contract address, `abi.encodePacked(address(this))`
- token coordinates resolved from `bindingOf(agentId)` on the binding contract
- token standard enum values: `0x00` = `ERC721`, `0x01` = `ERC1155`, `0x02` = `ERC6909`, `0x03` = `ERC1155F`, `0x04` = `ERC6909F`
- required verification surface: `bindingOf(uint256 agentId)`

The adapter intentionally goes beyond the ERC draft by also exposing:

- `register(...)` and `bindExisting(...)`
- `setAgentURI(...)`
- `setMetadata(...)`
- `setMetadataBatch(...)`
- `setAgentWallet(...)`
- `unsetAgentWallet(...)`
- `isController(...)`
- the counterfactual register family

## Admin Model

The adapter owner can:

- upgrade the adapter implementation
- change `identityRegistry`
- transfer adapter ownership to a new admin
- rewrite legacy `agent-binding` metadata into the current 20-byte format with `rewriteBindingMetadata(agentId)`

The admin does not have a function to rewrite user bindings. The admin controls upgradeability, registry configuration, and binding-metadata migration, not per-agent reassignment of the bound token through the current implementation.

## Contract Surface

User-facing functions:

- `register(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI, MetadataEntry[] metadata)`
- `register(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI)`
- `registerAndSetPrimary(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI)` — caller-paid `register` + set the new agent as the caller's own primary agent, in one tx
- `bindExisting(uint256 agentId, TokenStandard standard, address tokenContract, uint256 tokenId)`
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

Counterfactual (emit-only) functions:

- `counterfactualRegister(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI, MetadataEntry[] metadata)`
- `counterfactualRegister(TokenStandard standard, address tokenContract, uint256 tokenId, string agentURI)`
- `counterfactualSetAgentURI(TokenStandard standard, address tokenContract, uint256 tokenId, string newURI)`
- `counterfactualSetMetadata(TokenStandard standard, address tokenContract, uint256 tokenId, string metadataKey, bytes metadataValue)`
- `counterfactualSetMetadataBatch(TokenStandard standard, address tokenContract, uint256 tokenId, MetadataEntry[] metadata)`
- `counterfactualSetAgentWallet(TokenStandard standard, address tokenContract, uint256 tokenId, address newWallet)`
- `counterfactualUnsetAgentWallet(TokenStandard standard, address tokenContract, uint256 tokenId)`
- `registrationHash(address tokenContract, uint256 tokenId)`
- `interoperableAddress(address account)`
- `chainIdentifier()`
- `setPrimaryAgent(uint256 agentId)`
- `setPrimaryAgentFor(address account, uint256 agentId)`
- `clearPrimaryAgent()`
- `clearPrimaryAgentFor(address account)`
- `primaryAgentOf(address account)`
- `setPrimaryAgentWithSig(address account, uint256 agentId, uint256 deadline, bytes signature)`
- `clearPrimaryAgentWithSig(address account, uint256 deadline, bytes signature)`
- `primaryAgentNonces(address account)`
- `setPrimaryCounterfactualAgent(address tokenContract, uint256 tokenId)`
- `setPrimaryCounterfactualAgentFor(address account, address tokenContract, uint256 tokenId)`
- `clearPrimaryCounterfactualAgent()`
- `clearPrimaryCounterfactualAgentFor(address account)`
- `primaryCounterfactualAgentOf(address account)`

ERC-required verification function:

- `bindingOf(uint256 agentId)`

Adapter-specific convenience function:

- `isController(uint256 agentId, address account)`

Admin-facing functions:

- `initialize(address identityRegistry, address initialOwner)`
- `setIdentityRegistry(address newIdentityRegistry)`
- `rewriteBindingMetadata(uint256 agentId)`
- `upgradeToAndCall(address newImplementation, bytes data)`

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
- `bindExisting` for already-minted agents, including the approval and ownership checks
- delegate.xyz v2 hot/cold control for ERC-721, ERC-1155F, and ERC-6909F bindings
- immutable per-agent bindings
- repeated registration using the same external token
- control transfer after external token transfers
- metadata and URI updates
- wallet-binding pass-through with valid and invalid ERC-8004 signatures
- the counterfactual register family, including reserved-key rejection and the reserved `extraData` field
- proxy initialization
- admin-only registry repointing
- admin-only implementation upgrades

Tests:

- [`test/Adapter8004.t.sol`](/Users/nxt3d/projects/adapter/test/Adapter8004.t.sol)
