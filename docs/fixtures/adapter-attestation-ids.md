# Adapter8004 — attestation identifier fixture

Canonical formula:

```text
attestationId = keccak256(abi.encode(
    adapterInteroperableAddress, attester, cfid, attestationType, blockNumber, variant, data
))
```

Use ABI encoding for `(bytes,address,bytes32,bytes32,uint256,bytes32,bytes)`, not packed encoding.
There is no domain constant. The adapter is a full ERC-7930 Interoperable Address, exactly as in
`adapter-counterfactual-hashes.md`, and it is what binds every identifier to one adapter on one
chain. `attester` is the caller of the recording transaction. `blockNumber` is the block the
attestation lands in, which keeps identical statements in different blocks distinct. `variant` is
the caller-supplied within-block distinguisher and is `bytes32(0)` when unused.

**Every vector below is computed against the proxy address, the address users interact with.** The
identifier binds the emitting address, so a vector computed against an implementation address
would validate a deployment nobody uses. A conforming test reproduces the environment each vector
states — chain id, proxy address, caller, and block — and asserts the exact bytes. Never verify by
round trip: a round trip passes when both sides share the same bug.

## Type constants

Pinned against the hash of their exact defining strings. A reimplementation that disagrees with
any row has a typo in a defining string.

| Constant | Defining string | Value |
|---|---|---|
| `CONFIRM_ACCOUNT` | `adapter8004.attest.v1.confirm-account` | `0x0d1301b55a7106242fdc007f7371d46dbf2cef93819719bb571322d165ef0bdb` |
| `STAR` | `adapter8004.attest.v1.star` | `0xe57ebfd03b6f9111378311d8b209d3c35c5c9c45ce387029dbe32c0ff44b2651` |
| `RATING` | `adapter8004.attest.v1.rating` | `0xe29bafddb9bd210da3ccc8f60685504f8868bbcce6d9c216f35f0f841a6618b5` |
| `REVIEW` | `adapter8004.attest.v1.review` | `0x0ce439abec3b50d9bb4c1c26b71f5e02b7dac5a8f4546824b09b0066c94e6aed` |
| `INTERACTION` | `adapter8004.attest.v1.interaction` | `0x38bd7d6c19f392ef255c7033e6700c65ef16fc48f3ced5e18caf837f3231fedf` |

## Vector environment

All identifier vectors share one environment, chosen to line up with the counterfactual hash
fixture:

| Field | Value |
|---|---|
| Chain id | `1` |
| Proxy address | `0x1111111111111111111111111111111111111111` |
| Adapter Interoperable Address | `0x000100000101141111111111111111111111111111111111111111` |
| Caller `alice` | `0x00000000000000000000000000000000000a11ce` |
| Caller `bob` | `0x0000000000000000000000000000000000000b0b` |

The target `cfid` used below is a real five-component counterfactual hash, computed with the
standard in the preimage and the reserved zero discriminator:

```text
cfid = keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, extraData))
```

With the environment above, `boundAddress = 0x2222222222222222222222222222222222222222`, token id
`42`, `extraData = bytes32(0)`:

| Standard | Hash |
|---|---|
| `ERC721` (`uint8` 0) | `0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b` |
| `ERC1155` (`uint8` 1) | `0xa0822064813ff079eaead2d292b1cadd618d2350840f9813c5ee86605c6b654a` |

The two rows differ only in the standard and produce different identities, which is the point of
the five-component scheme. The four-component tables in `adapter-counterfactual-hashes.md` describe
the superseded scheme without the standard; an implementation reproducing those values for new
hashes is behind.

## Identifier vectors

All vectors use the `ERC721` cfid `0xefa9…7a0b` above. `type` names a constant from the table.

| # | Caller | Type | Block | `variant` | `data` | `attestationId` |
|---|---|---|---|---|---|---|
| 1 | alice | `CONFIRM_ACCOUNT` | `19000000` | `0` | empty | `0x80d05e729b10ebc5c0852c919bcb47c18342bac827ab09e307827dd576332e67` |
| 2 | alice | `CONFIRM_ACCOUNT` | `19000000` | `bytes32(1)` | empty | `0x97ff8f55126d26f62b78c5ec3b8908e1ab8bb76891d5e955832ab8cca1d0a202` |
| 3 | alice | `RATING` | `19000000` | `0` | `0x57` | `0x127945db7ff1b8f34cfd587ee3605c33c70d686af9ae9081413fd0929a70f6de` |
| 4 | bob | `CONFIRM_ACCOUNT` | `19000000` | `0` | empty | `0x1d000c7a6200f50086414eaab8e24343cca0a45518e82657ee5d652de28ebc87` |
| 5 | alice | `CONFIRM_ACCOUNT` | `19000001` | `0` | empty | `0x3b3f23c978049fa900522abac43b368325b25936825ed83e402a4214e4ab762a` |

Each pair of vectors pins one component's place in the formula. Vectors 1 and 2 differ only in
`variant`, 1 and 3 only in type and payload, 1 and 4 only in caller, 1 and 5 only in block.

```ts
import { encodeAbiParameters, keccak256 } from 'viem'
export function attestationId(
  adapterInteroperableAddress: `0x${string}`,
  attester: `0x${string}`,
  cfid: `0x${string}`,
  attestationType: `0x${string}`,
  blockNumber: bigint,
  variant: `0x${string}` = `0x${'00'.repeat(32)}`,
  data: `0x${string}` = '0x',
) {
  return keccak256(encodeAbiParameters(
    [{type:'bytes'}, {type:'address'}, {type:'bytes32'}, {type:'bytes32'}, {type:'uint256'}, {type:'bytes32'}, {type:'bytes'}],
    [adapterInteroperableAddress, attester, cfid, attestationType, blockNumber, variant, data],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, any preimage with a leading
domain constant, the fields in any other order, a naked adapter address in place of the
Interoperable Address, the implementation address in place of the proxy, and the transaction
sender's relayer or bundler in place of the calling account.

For any one adapter the two derivation schemes cannot collide by construction: the five-component
cfid encoding is a fixed 224 bytes and the identifier encoding is at least 320 bytes, so the two
preimages are never the same length.
