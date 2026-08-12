# Adapter8004 v0.0.16 — counterfactual hash fixture (ERC-7930 v1, canonical subject identifiers)

Canonical formula — one preimage for every subject kind (decision D6 in
[`docs/decisions/phase1-freeze.md`](../decisions/phase1-freeze.md)):

```text
registrationHash = keccak256(abi.encode(adapterInteroperableAddress, tokenContract, identifier))
```

with standard ABI encoding of `(bytes, address, bytes)` (never packed) and the canonical
subject identifier:

| Subject | Identifier | Length |
|---|---|---|
| The contract itself (`CONTRACT`, `CONTRACT_OWNABLE`) | empty (`0x`) | 0 |
| Plain token (all five token standards) | `0x00 ‖ tokenId` (full-width 32-byte big-endian) | 33 |
| Future kinds | `<kind byte ≥ 0x01> ‖ kind-defined layout` | per kind |

**Grammar rules (frozen).** Empty is reserved for the contract subject forever; every non-empty
identifier begins with an append-only kind byte; token ids are always full-width (a
minimal-length encoding would give one subject two identities); kind layouts never change once
published. The identifier is emitted on every counterfactual event, so any single event is
self-verifying against its indexed hash.

**Identity.** The identity is the `registrationHash`. Coordinates are non-unique attributes: a
contract's own identity (empty identifier) and its token id `0` (kind-`0x00` identifier) share a
coordinate while being distinct identities, and future kinds may add more.

The adapter is a full standard ERC-7930 v1 Interoperable Address (decision D1, revised: the
version bytes stay, matching OpenZeppelin and the interop ecosystem) and is not hashed first;
`tokenContract` is deliberately a naked EVM `address`. Chain binding comes from the adapter
Interoperable Address alone. For EVM:

```text
uint16(1) || uint16(0) || uint8(referenceLength)
|| shortest-nonempty-big-endian(block.chainid) || uint8(20) || bytes20(account)
```

The v1 encoding is frozen in the hash preimage permanently (spec invariant INV-1); hashes are
computable with stock ERC-7930 encoders. Derive
on-chain via `registrationHash(address,uint256)` (token subjects) and `registrationHash(address)`
(contract subjects).

## Vectors

With adapter `0x1111111111111111111111111111111111111111`, subject contract
`0x2222222222222222222222222222222222222222`:

Token subject, id `42` (`identifier = 0x00‖00…2a`):

| Namespace | Adapter Interoperable Address | Hash |
|---|---|---|
| Ethereum | `0x000100000101141111111111111111111111111111111111111111` | `0x2561a5127ce57aca2b3435b4ed6ed64f7c5b6751cfdc446b966689526719a6b2` |
| Base | `0x00010000022105141111111111111111111111111111111111111111` | `0xc85bfd30d7222052df213b1a9edb65d078c797f318571dd093b5d672bf2bb285` |
| Sepolia | `0x0001000003aa36a7141111111111111111111111111111111111111111` | `0x13dbefeafc7447b0e8affa009d7f3b45ad82ea4424751918250558dce70b0322` |
| Solana namespace stress example | `0x000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111` | `0xecafe1ffdf879b3f017085b8218f16a5460f933c9f43a1c8b93cda3e56645782` |

Contract subject (`identifier = 0x`, empty):

| Namespace | Hash |
|---|---|
| Ethereum | `0x7bcd28a8ab06672398163fa398bb414db0be5439508f0e96f7dd440cf2c43ea0` |
| Base | `0xe42152f115d09fc263b6dd6cba1c15b5942d8be411b24e702ceaed0d9cf2c445` |
| Sepolia | `0xc3e05023a35169e093cf930042ca89c5b4b24fb314b23194637e0707ec2febbd` |

Disambiguation vectors (Ethereum adapter bytes above):

| Case | Identifier | Hash |
|---|---|---|
| Token id `0` (NOT the contract subject) | `0x00‖00…00` (33 bytes) | `0x7e90bedaa189d8b5124fb6e56be1140283a8a16451546607fe0d42b892a2a2a8` |
| Illustrative future class kind (`0x01 ‖ class 2 ‖ id 123`) | 65 bytes | `0x1657a0aeeb5e08c43ffaafd8a9746524d2aae8ed7d45a82b734937cb788940ad` |

The Solana row is an adapter-chain namespace stress vector; its illustrative adapter address is
not a native Solana CAIP-350 address.

Local chain identifiers (chain-only form, AddressLength `0x00`):

| Chain | `chainIdentifier()` |
|---|---|
| Ethereum (1) | `0x00010000010100` |
| Base (8453) | `0x0001000002210500` |
| Sepolia (11155111) | `0x0001000003aa36a700` |

```ts
import { encodeAbiParameters, keccak256, concat, pad, toHex } from 'viem'

export function tokenIdentifier(tokenId: bigint): `0x${string}` {
  return concat(['0x00', pad(toHex(tokenId), { size: 32 })])
}

export function registrationHash(
  adapterInteroperableAddress: `0x${string}`,
  tokenContract: `0x${string}`,
  identifier: `0x${string}`,   // '0x' for the contract subject
) {
  return keccak256(encodeAbiParameters(
    [{ type: 'bytes' }, { type: 'address' }, { type: 'bytes' }],
    [adapterInteroperableAddress, tokenContract, identifier],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, a minimal-length token id, a
missing kind byte (raw 32-byte id), the superseded preimages below, a naked adapter address, and
any preimage that encodes `tokenContract` as an Interoperable Address.

## Superseded: v0.0.15 scheme (tuple preimage, trailing `extraData`)

Retained for identification only. Do not implement. Same ERC-7930 v1 adapter bytes as the current
scheme; the difference is the tuple preimage (raw `tokenId` plus `extraData`) instead of the
canonical identifier:

```text
keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId, bytes32(0)))
```

Same inputs (adapter `0x1111…`, token `0x2222…`, id `42`):

| Namespace | Superseded hash |
|---|---|
| Ethereum | `0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf` |
| Base | `0xaddf435e3042b0f79ee2a2c26e5ec3a7757b2fec663ca0f45547b09489d0e07e` |
| Sepolia | `0x5546dad5cfa9e0c3df6dff6ebca6d72e8bc3d707f2827c81e708a615cd24a2cb` |
| Solana namespace stress example | `0x725203cd24b34d707d2e8e9ae2dd74c7ea01e0cead262b4fe5fb483345c4d0d1` |

## Superseded: pre-v0.0.15 scheme (tuple preimage, no `extraData`)

Retained for identification only. Do not implement.

```text
keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId))
```

| Namespace | Superseded hash |
|---|---|
| Ethereum | `0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e` |
| Base | `0xd4f7e7c3e75d4d9c011d61c33666c7ba460bcb0a5964112643a31802fbf0791f` |
| Sepolia | `0xbd88f093e45b0adc6546b1363d8f876ac71cf52737abea2803edb5f938baeca5` |
| Solana namespace stress example | `0xa992e5d61c04f1741eccdd005ea76b2584ec995dd010df8c3303afc4270614cc` |

## Event ABIs

The D6 revision moves `topic0` for all six counterfactual events and
`PrimaryCounterfactualAgentSet`: indexed topics are now
`(registrationHash, tokenContract, emitter)`, the canonical `identifier` rides as the first body
field, and no counterfactual event carries a `tokenId` or `extraData` field. There is no
in-payload schema version — `topic0` discriminates schema on its own. Indexers must cut over to
the new ABI and the new hash values together.
