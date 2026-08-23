# Adapter8004 — ERC-7930 UBI fixture

Canonical formula:

```text
keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))
```

> **Scheme revision, v0.0.17.** The reserved `extraData` discriminator was removed from the preimage
> and from every counterfactual event, so every hash below changed again. It preserved no optionality:
> it was a compile-time constant no caller could reach, so every on-chain path derived with zero, and
> a non-zero identity could be attested to but never claimed or registered. What remains corresponds
> exactly to stored state, the adapter address plus exactly the `Binding`. The three superseded schemes
> are retained at the end of this document so that a reimplementer can tell which one their output
> matches. `standard` is a caller-supplied argument, because it selects the identity.

**Identity.** The identity is the UBI, the Universal Binding Identifier, which is the adapter address plus exactly
`(standard, boundAddress, tokenId)`. One coordinate under one standard is one identity, and the same
coordinate under two standards is two. Key on the UBI; never collapse rows by
`(boundAddress, tokenId)`, which does not name a standard.

**What the standard means here.** It records that the claimer passed *that standard's* authority
probe at claim time. It is not an assertion that the bound contract conforms to the ERC; the adapter
probes authority, never `supportsInterface`.

**Attestations key on these UBIs.** The attestation identifier scheme in
[`adapter-attestation-ids.md`](./adapter-attestation-ids.md) takes a UBI from this document as an
opaque target. The two schemes are derived by the same contract from overlapping material and cannot
collide, because for any one adapter the identifier preimage is always longer than this one. Both
carry the same adapter Interoperable Address, so both grow with it in step: writing `A` for the
adapter address padded up to a whole number of words and `D` for the payload padded the same way,
this preimage is `160 + A` bytes and the identifier preimage is `288 + A + D`. The identifier is
therefore at least 128 bytes longer, whatever the adapter address. For the EVM adapters in the table
below the concrete figures are 192 bytes here against at least 320 there. Because attestations
accumulate against these hashes, a scheme change orphans every statement made against the old value;
that is why both the standard insertion and the `extraData` removal landed before the attestation
surface shipped rather than after.

**The enum numbering is identity-critical.** `standard` enters the preimage as the enum's `uint8`, so
renumbering a `TokenStandard` member re-keys every identity claimed under it. The numbering is
append-only forever: never renumber, never reorder, never remove.

Use ABI encoding for `(bytes,uint8,address,uint256)`, not packed encoding. The adapter is a full
ERC-7930 Interoperable Address and is not hashed first. `boundAddress` is deliberately a naked EVM
`address`; do not encode it as an Interoperable Address. Chain binding comes from the adapter
Interoperable Address alone. For EVM, the adapter address is ERC-7930 v1 plus CAIP-350 `eip155`:

```text
uint16(1) || uint16(0) || uint8(referenceLength)
|| shortest-nonempty-big-endian(block.chainid) || uint8(20) || bytes20(account)
```

`TokenStandard` values: `ERC721 = 0`, `ERC1155 = 1`, `ERC6909 = 2`, `ERC1155F = 3`, `ERC6909F = 4`,
`ACCOUNT = 5`, `CONTRACT_OWNABLE = 6`, `CONTRACT_ADMIN = 7`.

With adapter `0x1111111111111111111111111111111111111111`, token
`0x2222222222222222222222222222222222222222`, token ID `42`, `standard = ERC721 (0)`:

| Namespace | Adapter Interoperable Address | Naked token contract | Hash |
|---|---|---|---|
| Ethereum | `0x000100000101141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9` |
| Base | `0x00010000022105141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x7caa0ee523b99d37d2073eef394484c7b7a29c6d8848a531641c6ad59ac675a3` |
| Sepolia | `0x0001000003aa36a7141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xc753b3b34ad2466a045e80c94ee26ac3a47054333762cb429ae7d8f17e12ac0f` |
| Solana namespace stress example | `0x000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x0f9c133f3a5c0ca7b20f94b3b57e5ac97f214b004e73fa71b1d6a2075deaa3cc` |

The final row is an adapter-chain namespace stress vector; its illustrative adapter address is not
a native Solana CAIP-350 address.

Same Ethereum envelope, same `(token, 42)`, varying only the standard. These four vectors are what
would move if the enum were ever renumbered:

| Standard | `uint8` | Hash |
|---|---|---|
| `ERC721` | `0` | `0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9` |
| `ERC1155` | `1` | `0x14cfea274e2d2b7367bffaa93dbfdda489fd4fbed711f949a321a75789fdec44` |
| `ACCOUNT` | `5` | `0x3d8eaa0572359ac90e967f6acdd9106d9c026f3c35872baa01de02f78a997c69` |
| `CONTRACT_OWNABLE` | `6` | `0x5bdc0e660d093b00b2552ec33586abf07d3b1572decf08bdd5563fa8c3180787` |

```ts
import { encodeAbiParameters, keccak256 } from 'viem'
export function ubiFor(
  adapterInteroperableAddress: `0x${string}`,
  standard: number,
  boundAddress: `0x${string}`,
  tokenId: bigint,
) {
  return keccak256(encodeAbiParameters(
    [{type:'bytes'}, {type:'uint8'}, {type:'address'}, {type:'uint256'}],
    [adapterInteroperableAddress, standard, boundAddress, tokenId],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, all three superseded preimages
below, the same fields with `standard` after the coordinates rather than before them, a different
`standard` value, any preimage carrying a trailing `bytes32(0)` discriminator, the superseded
`abi.encode(chainIdentifier, adapter, boundAddress, tokenId)` candidate, a naked adapter address, and
any preimage that encodes `boundAddress` as an Interoperable Address.

## Superseded: v0.0.17 pre-release scheme (`extraData` and standard)

Retained for identification only. Do not implement. This scheme was never deployed to any chain; it
existed in source only, between the standard's insertion and the discriminator's removal.

```text
keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, extraData))
```

Same inputs as the tables above, with `extraData = bytes32(0)`, the only value any caller could ever
observe:

| Namespace | Superseded hash |
|---|---|
| Ethereum | `0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b` |
| Base | `0x59d0dda43bf31104928591e57cb9ea008cdc5010d128f5e9a1f22976d67f66c2` |
| Sepolia | `0xda9417c2cab17e8973b2f8dc1661d856455d4877473006a492b1e4bc4b7960ff` |
| Solana namespace stress example | `0x9022fffd555f635b84981ac2056283d8325a432a0a01f3cac8ebf7cd4ba2cefc` |

And the standard-varying table under the same scheme:

| Standard | `uint8` | Superseded hash |
|---|---|---|
| `ERC721` | `0` | `0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b` |
| `ERC1155` | `1` | `0xa0822064813ff079eaead2d292b1cadd618d2350840f9813c5ee86605c6b654a` |
| `ACCOUNT` | `5` | `0xac6fc4a157cade654f49676a086bdcf2e514f0a21d5086cb22b6f9f1af59b029` |
| `CONTRACT_OWNABLE` | `6` | `0x06d91290d593090a0dc24da2056eb88f3c6a7e7f76f1a37a04061632933d9cb1` |

## Superseded: v0.0.15–v0.0.16 scheme (`extraData`, no standard)

Retained for identification only. Do not implement. This scheme was never deployed to any chain; it
existed in source only.

```text
keccak256(abi.encode(adapterInteroperableAddress, boundAddress, tokenId, extraData))
```

Same inputs as above (adapter `0x1111…1111`, token `0x2222…2222`, token ID `42`,
`extraData = bytes32(0)`):

| Namespace | Superseded hash |
|---|---|
| Ethereum | `0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf` |
| Base | `0xaddf435e3042b0f79ee2a2c26e5ec3a7757b2fec663ca0f45547b09489d0e07e` |
| Sepolia | `0x5546dad5cfa9e0c3df6dff6ebca6d72e8bc3d707f2827c81e708a615cd24a2cb` |
| Solana namespace stress example | `0x725203cd24b34d707d2e8e9ae2dd74c7ea01e0cead262b4fe5fb483345c4d0d1` |

Under this scheme any two standards claiming one `(boundAddress, tokenId)` aliased onto a single
identity. That aliasing is what v0.0.17 removes.

## Superseded: pre-v0.0.15 scheme (no `extraData`, no ERC-7930)

Retained for identification only. Do not implement. **This is the scheme still running on every live
proxy** as of 2026-08-19, so an indexer reading mainnet, Base or Sepolia today reproduces this table
and no other.

```text
keccak256(abi.encode(block.chainid, adapterAddress, boundAddress, tokenId))
```

With the live proxy addresses, token `0x0000…0001`, token ID `0`:

| Chain | Proxy | Live hash |
|---|---|---|
| Ethereum | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0xe07366d2d52aa30e7d2cd2a2b9144d4a95e22f8f8973662aad59983b630957c8` |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0x8d4d84d0cd3f4009b540e98b0376832e91569e65d695c4b147c29ab81f10405c` |
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0xe87a4370c6dbeb91353a0e686b69108d4f97d4b12593742b3e29631ba48abcd2` |

There is also an intermediate ERC-7930 candidate that existed in v0.0.14 source and was never
deployed, `abi.encode(adapterInteroperableAddress, boundAddress, tokenId)`. For the same inputs as
the vector tables above its Ethereum value is
`0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e`.

If your implementation reproduces the live table, you are on the deployed scheme and must cut over
before the upgrade.

The counterfactual event signatures changed alongside each scheme, and `topic0` is the keccak of the
full signature, so it discriminates schema on its own. At v0.0.15 every event gained a non-indexed
`bytes32 extraData` and the former `uint8 version` field was removed. At v0.0.17 the five
counterfactual update events and `WalletUBISet` each gained a non-indexed `uint8
standard`, and then `extraData` was dropped from all six of those plus `CounterfactualAgentRegistered`
and `CounterfactualAgentWalletUnset`, so `topic0` moved once more for every counterfactual event. A
single log line still carries everything needed to recompute the hash it names. The current values
are:

| Event | `topic0` |
|---|---|
| `CounterfactualAgentRegistered(bytes32,address,uint256,uint8,string,(string,bytes)[],address)` | `0x97d00c8567205a5cc677f706846d109951c59a16a119d3ebc5257e2abb21d2de` |
| `CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)` | `0x208006a8f39020b431e3b41391b77cee3f3484699443ec87628668357a203032` |
| `CounterfactualMetadataSet(bytes32,address,uint256,uint8,string,bytes,address)` | `0xe180e66feab1e2a5e41801375bae16bd8c51c3a049c9f8807e1c4d94411eb745` |
| `CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)` | `0xeae9f3081237409ccdb4af04402271802d256ead57b5ca5eefb6b0b61c62715a` |
| `CounterfactualAgentWalletSet(bytes32,address,uint256,uint8,address,address)` | `0xe8fa73832d285f8d56860e6d330c5b5fd1793f142062ccfa2cd2f9322f96b7e8` |
| `CounterfactualAgentWalletUnset(bytes32,address,uint256,uint8,address)` | `0x531cc4f9206c5d286ad84b9b965069e88bfd025f84a64b41bb58d9bfb3b503d8` |
| `WalletUBISet(address,bytes32,address,uint256,uint8,address)` | `0xc53d80905aaf1d8095f570fa85c068ab1a7e1e496c173d5cf3f3d3761b56a761` |
