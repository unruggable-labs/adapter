# ERC-8004 Identity Adapter

Adapter8004 lets a token holder, account, or contract controller manage an ERC-8004 identity.
The adapter proxy owns the identity NFT; a binding determines who can update its record.

This README describes the source version in [Adapter8004.sol](./src/Adapter8004.sol), not every deployed implementation.
Check [Deployments](#deployments) before integrating with a live proxy.

## How it works

```text
  ┌───────────────────┐
  │ Authorized caller │
  └─────────┬─────────┘
            │ register(standard, boundAddress, tokenId, agentURI)
            ▼
  ┌───────────────────┐     register      ┌────────────────────┐
  │   Adapter proxy   │ ─────────────────▶ │ ERC-8004 registry  │
  │ checks authority  │                   └─────────┬──────────┘
  │ stores binding    │                             │
  └───────────────────┘ ◀───────────────────────────┘
                           mints agent NFT to adapter
```

1. A caller passes the authority check for a binding.
2. The adapter registers an identity in the ERC-8004 registry.
3. The registry mints the identity NFT to the adapter.
4. The adapter stores the binding and clears the registry's default agent wallet.
5. Later updates require current authority under that binding.

A binding contains `(standard, boundAddress, tokenId)`.
The current implementation has no rebind, unbind, withdrawal, or existing-agent import function.
One binding can be used to register several agent IDs.

For example, transferring a bound ERC-721 transfers control of its agent record to the new token owner.
The ERC-8004 identity NFT stays in the adapter.

```text
  ┌─────────┐       transfer bound NFT #1       ┌─────────┐
  │  Alice  │ ────────────────────────────────▶ │   Bob   │
  └─────────┘                                  └────┬────┘
                                                    │ update agent
                                                    ▼
                                          ┌──────────────────┐
                                          │  Adapter proxy   │
                                          │ checks current   │
                                          │ owner of NFT #1  │
                                          └─────────┬────────┘
                                                    │ authorized update
                                                    ▼
                                          ┌──────────────────┐
                                          │ ERC-8004 record  │
                                          │ NFT still owned  │
                                          │ by the adapter   │
                                          └──────────────────┘
```

## Control rules

Authority is checked on each registration or update; the original registrant has no lasting privilege.

| Value | Standard | Direct authority | delegate.xyz authority |
| --- | --- | --- | --- |
| 0 | `ERC721` | Current nonzero `ownerOf(tokenId)` | Token, contract, or wallet-wide grant from that owner |
| 1 | `ERC1155` | Positive `balanceOf(account, tokenId)` | None |
| 2 | `ERC6909` | Positive `balanceOf(account, tokenId)` | None |
| 3 | `ERC1155F` | Current nonzero `ownerOf(tokenId)` | Same as ERC721 |
| 4 | `ERC6909F` | Current nonzero `ownerOf(tokenId)` | Same as ERC721 |
| 5 | `ACCOUNT` | The bound address itself | Wallet-wide grant from that address |
| 6 | `CONTRACT_OWNABLE` | Current nonzero `owner()` | Contract or wallet-wide grant from that owner |
| 7 | `CONTRACT_ADMIN` | Holder of `DEFAULT_ADMIN_ROLE` | None |

Values 5–7 require `tokenId == 0`; other values revert.
All standards reject the zero address and the configured identity registry.
All except `ACCOUNT` require deployed code at `boundAddress`.

ERC1155 and ERC6909 bindings allow shared control when several accounts hold a positive balance.
ERC1155F and ERC6909F use the single-owner `ownerOf` profile.
The adapter checks authority, not ERC conformance: it does not call `supportsInterface`.

Standard numbers are part of stored bindings and identity hashes.
Append new values; never renumber, reorder, or remove existing values.

### Delegation

The adapter queries delegate.xyz v2 at `0x00000000000000447e69651d841bD8D104Bed493`.
A grant must cover `keccak256("adapter8004.manage")` or use unscoped rights.

Direct authority is checked first.
If the delegation registry has no code, delegation grants no authority.
Delegations are read live, so revocation removes delegated access.

Plain ERC1155, ERC6909, and CONTRACT_ADMIN bindings have no delegation path.
A wallet-wide grant can authorize an ACCOUNT binding even if the grant predates registration.

### Account-level bindings

Choose `ACCOUNT` when the address itself should control the identity.
For a contract to act directly, it must be able to call the adapter; it can register from its constructor.
Its owner or admin gains no authority unless separately authorized through a qualifying delegation.

Choose `CONTRACT_OWNABLE` for management by the contract's current owner or that owner's delegates.
Choose `CONTRACT_ADMIN` for management by its default admins.
Neither standard grants special authority merely because the caller is the bound contract.

The `owner()` probe accepts only a successful 32-byte canonical address response.
Zero, malformed responses, and reverts grant no owner authority.
The `hasRole(bytes32(0), account)` probe accepts only a successful 32-byte word equal to `1`.

Ownership transfers and role changes affect existing bindings immediately.
If `owner()` becomes zero, an OWNABLE binding cannot be managed unless the bound contract later restores a valid owner.

Authorization uses the immediate `msg.sender`.
A router or relayer must qualify under the selected rule; forwarding a user's address does not confer authority.
EIP-7702 and smart-wallet execution policies determine who can cause calls from an ACCOUNT address.
Changing those policies can widen or narrow access without changing the binding.

Call the adapter proxy normally; do not delegatecall its implementation into another contract's storage.

### Ownerless token registration

For ERC721, ERC1155F, and ERC6909F, the bound token contract may directly call `register` or a counterfactual writer while `ownerOf(tokenId)` reverts or returns zero.
The contract must already have runtime code.
A successful but malformed `ownerOf` response reverts; it does not establish ownerlessness.

This permits registration immediately before minting.
A burn can reopen the same window; it is not proof that the ID was never minted.
Once a nonzero owner exists, the collection needs normal owner or delegate authority.

The exception does not authorize management of an already-registered agent through `setAgentURI`, metadata, or wallet setters.
Those functions require a current controller.

`isController(agentId, account)` returns false for an unknown agent.
For known agents, external ownership, balance, or delegation calls can revert; callers must not assume it always returns a boolean.

## Register and manage an agent

Register with or without metadata:

```solidity
register(standard, boundAddress, tokenId, agentURI, metadata)
register(standard, boundAddress, tokenId, agentURI)
```

Both overloads return the new registry `agentId`.
The adapter writes the binding, stores its proxy address under `agent-binding`, and calls `unsetAgentWallet` to remove the registry's default wallet assignment.

Current controllers can call:

- `setAgentURI(agentId, newURI)`
- `setMetadata(agentId, key, value)`
- `setMetadataBatch(agentId, entries)`
- `setAgentWallet(agentId, newWallet, deadline, signature)`
- `unsetAgentWallet(agentId)`

Read functions include `bindingOf`, `bindingHashOf`, `isController`, `getMetadata`, `getAgentWallet`, `ownerOf`, and `tokenURI`.
The last four forward to the configured registry.
For a bound agent, `ownerOf(agentId)` reports the adapter proxy, not its controller.

Registered wallet assignments retain the registry's signature checks.
For the registry's EIP-712 wallet authorization, use the adapter proxy as the `owner` field, not the external token holder.
The registry validates EOA signatures or the wallet's ERC-1271 response.

Do not transfer existing identity NFTs or unrelated NFTs to the adapter.
Its ERC-721 receiver accepts transfers, but receiving an NFT creates no binding and the current implementation has no rescue function.

## Binding metadata and verification

The adapter's discovery interface is [IERC8217](./src/interfaces/IERC8217.sol).

| Field | Value |
| --- | --- |
| Registry metadata key | `agent-binding` |
| Metadata value | `abi.encodePacked(adapterProxy)`: exactly 20 bytes |
| Binding lookup | `bindingOf(agentId)` on that proxy |
| Returned fields | `standard`, `boundAddress`, `tokenId` |

To resolve a binding, read the metadata address, then call `bindingOf` at that address.
Use `isController` to check this adapter's authority rules; it is an adapter-specific helper.

`agent-binding` is the only reserved metadata key on registered and counterfactual writes.
Caller-supplied values for that key revert.
Other keys, including `cf-registration`, are user data and must not be trusted as adapter-authored binding evidence.

## UBIDs

A Universal Binding Identifier (UBID) identifies the binding within this adapter and chain:

```text
keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))
```

Encode the fields as `(bytes,uint8,address,uint256)`, not packed encoding.
The adapter address uses the local [ERC-7930](https://eips.ethereum.org/EIPS/eip-7930) envelope; `boundAddress` remains a plain EVM address.

- `hashBinding(standard, boundAddress, tokenId)` computes a UBID without validating the binding or checking authority.
- `bindingHashOf(agentId)` derives it from a stored binding and reverts for an unknown agent.
- `interoperableAddress(account)` encodes an address on the current chain.
- `chainIdentifier()` returns the chain envelope with no address.

Different standards at the same address and token ID produce different UBIDs.
Several registered agent IDs can share one UBID if they use the same binding.

The implementation uses OpenZeppelin's `InteroperableAddress.formatEvmV1`.
Run the [frozen encoding tests](./test/Adapter8004.erc7930-frozen.t.sol) after dependency changes; changing the encoding changes identity hashes.
See the [UBID fixtures](./docs/fixtures/adapter-counterfactual-hashes.md) for vectors and historical schemes.

## Counterfactual registration

Counterfactual functions emit identity claims without minting a registry NFT or storing a binding.
They still consume transaction gas and use the registration authority rules above.

Each function below returns the UBID it emits:

- `counterfactualRegister(standard, boundAddress, tokenId, agentURI, metadata)`
- `counterfactualRegister(standard, boundAddress, tokenId, agentURI)`
- `counterfactualSetAgentURI(standard, boundAddress, tokenId, newURI)`
- `counterfactualSetMetadata(standard, boundAddress, tokenId, key, value)`
- `counterfactualSetMetadataBatch(standard, boundAddress, tokenId, entries)`
- `counterfactualSetAgentWallet(standard, boundAddress, tokenId, newWallet)`
- `counterfactualUnsetAgentWallet(standard, boundAddress, tokenId)`

Wallet assignment here checks identity authority but does not require the named wallet's consent.
It creates no registered ERC-8004 wallet assignment.

There is no delete-claim function.
A later counterfactual registration replaces the full claim payload; setters update individual fields.
An unset-wallet event clears only the wallet field.

Calling `register` later creates a separate registry record.
The shared UBID lets an indexer join its history to the counterfactual claim; registration does not copy earlier event metadata into the registry.

### Wallet UBID self-claims

`setWalletUBID(standard, boundAddress, tokenId)` emits the caller's reverse claim and returns the derived UBID.
It validates the address and canonical token ID, but does not require identity control or an existing registration.
`clearWalletUBID()` emits a clear for the caller, including when no claim exists.

Only the wallet itself can set or clear its claim.
A smart wallet must execute the call through its own authorization policy.
An owner, delegate, or relayer calling directly can claim only for its own address.

`counterfactualSetAgentWalletAndUBID(standard, boundAddress, tokenId)` requires identity authority and emits both directions in one call: identity-to-caller and caller-to-UBID.
It returns that UBID.

These claims are event-only; there is no wallet mapping or on-chain getter.
Indexers apply `WalletUBIDSet` and `WalletUBIDCleared` per account in log order.
A reverse claim alone does not prove a mutual link; also check the identity's current forward wallet assignment.

## Attestations

Attestations record public statements about a UBID.
The immediate caller is the attester; no identity authority is required.

- `attest(attestationType, ubid, variant, data)` emits `Attested`.
- `confirmAdditionalAccount(ubid)` is equivalent to a CONFIRM_ACCOUNT attestation with zero variant and empty data.
- `revoke(attestationId)` emits `AttestationRevoked`.

The attestation ID is emitted, not returned:

```text
keccak256(abi.encode(
    adapterInteroperableAddress, attester, ubid, attestationType, block.number, variant, data
))
```

Identical inputs in the same block produce the same ID.
Use a different `variant` to distinguish repeated statements within a block.

| Value | Type | Reader-required payload |
| --- | --- | --- |
| 0 | `UNSPECIFIED` | Rejected by the contract |
| 1 | `CONFIRM_ACCOUNT` | Empty |
| 2 | `STAR` | One byte: 0 or 1 |
| 3 | `RATING` | One byte: 0–100 |
| 4 | `REVIEW` | Nonempty UTF-8 text |
| 5 | `INTERACTION` | Score byte 0–100, 32-byte reference, optional UTF-8 text |

The ABI rejects out-of-range enum values.
The contract rejects UNSPECIFIED and a zero target UBID, but does not validate payloads or target existence.
Revocation accepts any ID; readers must ignore unknown IDs and revocations by anyone other than the original attester.

No attestation state is stored or exposed through a getter.
Readers must apply the [type and projection rules](./docs/specs/attestation-type-registry-v1.md), including re-attestation after revocation.
See the [attestation fixtures](./docs/fixtures/adapter-attestation-ids.md) for identifier vectors.

## Indexing and upgrades

Use the ABI for the implementation active when each event was emitted.

- Registered bindings use `AgentBound`; `agentId`, `standard`, and `boundAddress` are indexed.
- Counterfactual identity events index `ubid`, `boundAddress`, and `tokenId`; `standard` is in the body.
- Group counterfactual records by UBID, not just address and token ID.
- Apply canonical-chain logs by block number and log index; undo records removed by a reorganization.
- Treat event-schema and hash-scheme changes as explicit cutovers.
- Preserve historical hashes; computing the current hash does not rewrite old event identities.
- `setMetadataBatch` emits one `MetadataSet` per entry; the current contract has no `MetadataBatchSet` event.

Record the executed upgrade transaction and exact log boundary.
Implementation deployment alone changes neither the proxy nor its event stream.

The [Sepolia preflight](./deployments/v0.0.17-sepolia-preflight.md) lists changes from the deployed baseline.
Older migration documents describe intermediate releases; do not use their API or storage descriptions as the current specification.

## Architecture and admin authority

The adapter uses an ERC1967Proxy with a UUPS implementation.
The implementation constructor sets `identityRegistry`; `initialize(initialOwner)` sets a new proxy's owner.

The owner can upgrade, transfer ownership, or renounce ownership.
The current implementation gives the owner no special authority to manage an individual agent.
However, upgrade authority can replace those rules; bindings are not immutable against an owner-authorized code change.

The registry has no setter and is immutable within one implementation.
**Upgrades check ownership only, not registry equality.**
Operators must preserve the registry: another registry can reuse agent IDs and cause new registrations to overwrite existing bindings.

For the documented deployed baselines, slot 0 holds the old registry address and slot 1 holds bindings.
The current implementation reserves slot 0 and keeps bindings at slot 1.
Wallet claims and attestations add no storage mappings.
Upgrade existing proxies with empty initialization data; do not call `initialize` again.

## Deployments

Use proxy addresses for integrations.

| Chain | Adapter proxy | Identity registry |
| --- | --- | --- |
| Ethereum | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |

Recorded owner Safe: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` on all three chains.

| Chain | Last checked | Active implementation at that check |
| --- | --- | --- |
| Ethereum | 2026-07-29 | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` |
| Base | 2026-07-29 | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` |
| Sepolia | 2026-09-07 | `0x31a68E5bc0224ad081d6Ec20229B05F558609257` |

These checks do not show the current source deployed.
See the [historical baseline](./deployments/upgrade-baseline-from-last-deployed.md) and [Sepolia preflight](./deployments/v0.0.17-sepolia-preflight.md) for evidence.

Before an upgrade, re-read the proxy's EIP-1967 implementation slot:

```text
0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

A prepared Safe payload or a deployed implementation is not evidence of an executed upgrade.

## Build and test

The [Foundry configuration](./foundry.toml) pins solc 0.8.30, Prague, and 200 optimizer runs.

```sh
forge build
forge test
forge fmt --check
```

The Sepolia fork test requires an RPC URL; otherwise it skips:

```sh
SEPOLIA_FORK_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
SEPOLIA_FORK_BLOCK=11655563 forge test
```

Tests cover authority checks, malformed responses, registry signatures, immutable binding storage,
delegation, event projections, encoding vectors, and upgrades.
The [Sepolia fork test](./test/Adapter8004.sepolia-fork.t.sol) also preserves historical bindings through an upgrade using the actual deployed registries.
It impersonates the Safe locally; it does not validate Safe signatures or submit transactions.

## Deploy a new proxy

This creates a new adapter address; it does not upgrade an existing deployment.

Copy [.env.example](./.env.example) to `.env`.
Set `DEPLOYER_PRIVATE_KEY` and the selected network's RPC and identity-registry variables.
Never commit a private key.

The following commands broadcast an implementation and a new proxy:

```sh
script/deploy.sh sepolia
# Alternatives: script/deploy.sh base or script/deploy.sh mainnet
```

The deployer becomes the new proxy's owner.
Use [TransferAdapterOwnership.s.sol](./script/TransferAdapterOwnership.s.sol) to transfer ownership when required.

## Upgrade an existing Safe-owned proxy

1. Confirm the live implementation, registry, owner, storage compatibility, and indexer cutover.
2. Deploy only the implementation with [DeployAdapterImplementation.s.sol](./script/DeployAdapterImplementation.s.sol), passing the unchanged registry to its constructor.
3. Verify its source, constructor argument, runtime code, and deployment receipt.
4. Generate Safe calldata using the actual deployed address.
5. Have the Safe execute `upgradeToAndCall(newImplementation, 0x)` against the existing proxy.
6. Re-read the implementation slot, owner, registry, and sampled bindings after execution.

For Sepolia, follow the [preflight report](./deployments/v0.0.17-sepolia-preflight.md).
After deploying and verifying the implementation, set `ADAPTER_IMPLEMENTATION_ADDRESS` and `EXPECTED_IMPLEMENTATION_CODEHASH`, then prepare the Safe JSON:

```sh
forge script script/PrepareSepoliaUpgrade.s.sol:PrepareSepoliaUpgradeScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

This preparation script checks the deployed target and simulates the upgrade locally.
It rejects `--broadcast` and `--resume`.
Its output is `deployments/v0.0.17-safe-tx-sepolia-verified.json`.

The Safe transaction is a CALL to the proxy with value zero and empty post-upgrade initialization data.
Do not sign an implementation address taken only from a deployment dry run.
The direct-owner [UpgradeAdapter.s.sol](./script/UpgradeAdapter.s.sol) is not the execution path for a Safe-owned proxy.

## Source reference

- [Adapter implementation](./src/Adapter8004.sol)
- [Binding types and views](./src/interfaces/IERC8217.sol)
- [Registration interface](./src/interfaces/IERC8004AdapterRegistration.sol)
- [Registry record interface](./src/interfaces/IERC8004IdentityRecord.sol)
- [Counterfactual and wallet-claim interface](./src/interfaces/IERC8004AdapterCounterfactual.sol)
- [Attestation interface](./src/interfaces/IERC8004AdapterAttestation.sol)
- [Release history](./CHANGELOG.md)
