# Adapter

Adapter is a protocol for agent identity and reputation across blockchains.
An agent profile associates a token or account with agent metadata and is identified by a Universal Binding Identifier (UBID).
The UBID includes the binding's chain and Adapter deployment, giving applications an unambiguous identifier across networks.

Attestations let accounts publish statements about a profile, providing a record that applications can use to assess reputation.
Applications can also associate payments on different blockchains with a profile's UBID.

Adapter supports counterfactual profiles through event-based identity claims, wallet links, and attestations.
The protocol also supports ERC-8004 registration, letting agents have a registry record and identity NFT bound to their token or account.

This README describes the source version in [the implementation contract](./src/AdapterImplementation.sol), not every deployed implementation.
Check [Deployments](#deployments) before integrating with a live proxy.

## How it works

A binding describes the token or account associated with a profile: `(standard, boundAddress, tokenId)`.
It determines who can publish or update the profile, and its UBID identifies it within an Adapter deployment and chain.

1. Choose a token or account and its [control rule](#control-rules).
2. Choose how to publish the profile using one of the two paths below. Both accept an agent URI and optional metadata, and check the caller's authority under the binding.
3. Manage the profile through the chosen path's update functions. Authority is checked on each write, using the current controller of the token or account.
4. Use the UBID for [wallet links](#wallet-ubid-self-claims) and [attestations](#attestations). These work with either path and also independently of profile publication; each has its own authorization rules.

| Profile path | Publish | Manage and read |
| --- | --- | --- |
| [Counterfactual registration](#counterfactual-registration) | Call `counterfactualRegister` to emit the profile under its UBID. | Use the counterfactual setters to publish updates. Indexers reconstruct the profile from events; no ERC-8004 NFT is minted and no binding is stored. |
| [ERC-8004 registration](#erc-8004-registration-and-management) | Call `register` to create a registry record, mint its identity NFT to the Adapter, and store the binding. The call returns an `agentId`. | Use the registered-agent setters with the `agentId`. Read the record through the registry or Adapter's forwarding getters. |

Both paths use the same UBID for the same binding within an Adapter deployment and chain.
You can derive the [UBID](#ubids) at any time with `hashBinding(standard, boundAddress, tokenId)`; this read call requires no registration or transaction.
Counterfactual events describe one profile per UBID.
ERC-8004 registration associates an identity with that UBID, and each registration creates a new `agentId`.
A UBID can have one or more ERC-8004 identities associated with it.

Control follows the current token owner, holder, account, or contract authority selected by the binding standard.
For example, transferring a bound ERC-721 transfers authority to update its profile to the new owner, whether the profile uses event-based claims or an ERC-8004 record.

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
The Adapter checks who can manage the profile, but does not verify that the token or contract fully follows the selected standard.

### Delegation

Adapter uses delegate.xyz to delegate profile management to another account. For example, you can keep your asset in a hardware wallet and manage its agent profile from a hot wallet.

Adapter uses the `adapter8004.manage` delegation grant. Grants covering all rights are also accepted.

Plain ERC1155, ERC6909, and CONTRACT_ADMIN bindings have no delegation path.

### Account-level bindings

These types bind a profile to a wallet or contract rather than an individual token:

- `ACCOUNT`: The wallet or contract itself manages the profile. It can also authorize another account through delegate.xyz.
- `CONTRACT_OWNABLE`: The contract's current owner, or that owner's delegates, manages the profile.
- `CONTRACT_ADMIN`: The contract's default admins manage the profile.

Changes to the contract's owner or admins change who can manage the profile.

### Ownerless token registration

Binding a profile at mint should be gas efficient. Previously, a collection had to mint the token to its own contract, bind the profile, then transfer the token to the user.

For `ERC721`, `ERC1155F`, and `ERC6909F`, Adapter lets the deployed token contract bind a profile before the token has an owner. The collection can then mint directly to the user, avoiding the extra transfer and its gas cost. This works with both ERC-8004 registration and counterfactual publication.

Once the token has an owner, managing its profile requires the owner's or a delegate's permission.
Updating an existing ERC-8004 record always requires a current controller, even when the token has no owner.

## ERC-8004 registration and management

Use `register` to add an ERC-8004 registry record and identity NFT to a binding's UBID.
Event-based profiles, wallet claims, and attestations also work independently, so you can choose ERC-8004 registration to suit your application's needs.

```text
  ┌───────────────────┐
  │ Authorized caller │
  └─────────┬─────────┘
            │ register(standard, boundAddress, tokenId, agentURI)
            ▼
  ┌───────────────────┐     register      ┌────────────────────┐
  │   Adapter proxy   │ ────────────────▶ │ ERC-8004 registry  │
  │ checks authority  │                   └─────────┬──────────┘
  │ stores binding    │                             │
  └───────────────────┘ ◀───────────────────────────┘
                           mints agent NFT to Adapter
```

1. A caller passes the authority check for a binding.
2. The Adapter registers an identity in the ERC-8004 registry.
3. The registry mints the identity NFT to the Adapter.
4. The Adapter stores the binding and clears the registry's default agent wallet.
5. Later updates require current authority under that binding.

For example, transferring a bound ERC-721 transfers control of its agent record to the new token owner.

```text
  ┌─────────┐       transfer bound NFT #1     ┌─────────┐
  │  Alice  │ ──────────────────────────────▶ │   Bob   │
  └─────────┘                                 └────┬────┘
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
                                          │ by the Adapter   │
                                          └──────────────────┘
```

Register with or without metadata:

```solidity
register(standard, boundAddress, tokenId, agentURI, metadata)
register(standard, boundAddress, tokenId, agentURI)
```

Both overloads return the new registry `agentId`.
The Adapter writes the binding, stores its proxy address under `agent-binding`, and calls `unsetAgentWallet` to remove the registry's default wallet assignment.

Current controllers can call:

- `setAgentURI(agentId, newURI)`
- `setMetadata(agentId, key, value)`
- `setMetadataBatch(agentId, entries)`
- `setAgentWallet(agentId, newWallet, deadline, signature)`
- `unsetAgentWallet(agentId)`

Read functions include `bindingOf`, `bindingHashOf`, `isController`, `getMetadata`, `getAgentWallet`, `ownerOf`, and `tokenURI`.
The last four forward to the configured registry.
For a bound agent, `ownerOf(agentId)` reports the Adapter proxy, not its controller.

Registered wallet assignments retain the registry's signature checks.
For the registry's EIP-712 wallet authorization, use the Adapter proxy as the `owner` field, not the external token holder.
The registry validates EOA signatures or the wallet's ERC-1271 response.

Do not transfer existing identity NFTs or unrelated NFTs to the Adapter.
Its ERC-721 receiver accepts transfers, but receiving an NFT creates no binding and the current implementation has no rescue function.

## Binding metadata and verification

The Adapter's discovery interface is [IERC8217](./src/interfaces/IERC8217.sol).

| Field | Value |
| --- | --- |
| Registry metadata key | `agent-binding` |
| Metadata value | `abi.encodePacked(adapterProxy)`: exactly 20 bytes |
| Binding lookup | `bindingOf(agentId)` on that proxy |
| Returned fields | `standard`, `boundAddress`, `tokenId` |
| Binding identifier | `bindingHashOf(agentId)` on that proxy |

Adapter targets the expected ERC-8217 update and exposes both functions:

- `bindingOf(uint256 agentId) returns (Binding)` returns the stored binding.
- `bindingHashOf(uint256 agentId) returns (bytes32)` returns the binding's UBID.

To resolve a binding, read the metadata address, then call both functions at that address.
Verify the returned UBID against the binding fields before joining records from other chains or event histories.
Use `isController` to check this Adapter's authority rules; it is an Adapter-specific helper.

`agent-binding` is the only reserved metadata key on registered and counterfactual writes.
Caller-supplied values for that key revert.
Other keys, including `cf-registration`, are user data and must not be trusted as Adapter-authored binding evidence.

## UBIDs

A Universal Binding Identifier (UBID) identifies the binding within this Adapter and chain:

```text
keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))
```

Encode the fields as `(bytes,uint8,address,uint256)`, not packed encoding.
The Adapter address uses the local [ERC-7930](https://eips.ethereum.org/EIPS/eip-7930) envelope; `boundAddress` remains a plain EVM address.

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

Counterfactual functions publish and update an event-based profile without minting a registry NFT or storing a binding.
These profiles work independently of ERC-8004 registration. Agents can also register in the ERC-8004 registry at any time.
These calls still consume transaction gas and use the binding authority rules above.

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
The immediate caller is the attester; no identity authority or prior registration of the target is required.

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

## Deployments

Use proxy addresses for integrations.

| Chain | Adapter proxy | Identity registry |
| --- | --- | --- |
| Ethereum | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |

| Chain | Last checked | Active implementation at that check |
| --- | --- | --- |
| Ethereum | 2026-07-29 | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` |
| Base | 2026-07-29 | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` |
| Sepolia | 2026-09-07 | `0x31a68E5bc0224ad081d6Ec20229B05F558609257` |

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

## Source reference

- [Adapter implementation](./src/AdapterImplementation.sol)
- [Binding types and views](./src/interfaces/IERC8217.sol)
- [Registration interface](./src/interfaces/IERC8004AdapterRegistration.sol)
- [Registry record interface](./src/interfaces/IERC8004IdentityRecord.sol)
- [Counterfactual and wallet-claim interface](./src/interfaces/IERC8004AdapterCounterfactual.sol)
- [Attestation interface](./src/interfaces/IERC8004AdapterAttestation.sol)
- [Release history](./CHANGELOG.md)
