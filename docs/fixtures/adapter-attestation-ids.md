# Adapter8004 — attestation identifier fixture

Canonical formula:

```text
attestationId = keccak256(abi.encode(
    adapterInteroperableAddress, attester, cfid, attestationType, blockNumber, variant, data
))
```

Use ABI encoding for `(bytes,address,bytes32,uint8,uint256,bytes32,bytes)`, not packed encoding.
`attestationType` is the `AttestationType` enum encoded as its `uint8`, right-aligned in a full
32-byte word, which is what `abi.encode` of a Solidity enum produces.
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

## Attestation types

The type is a Solidity enum, so the values are small integers rather than hashes of defining
strings. The numbering is **identity-critical**: the `uint8` is in the identifier preimage, so
renumbering a member re-keys every attestation ever emitted under it. Append only, never reorder,
never remove.

| Member | `uint8` |
|---|---|
| `UNSPECIFIED` | `0` |
| `CONFIRM_ACCOUNT` | `1` |
| `STAR` | `2` |
| `RATING` | `3` |
| `REVIEW` | `4` |
| `INTERACTION` | `5` |

`UNSPECIFIED` is the reserved sentinel and is never a real type; the contract rejects it with
`AttestationTypeZero`. A value above the last member is rejected by the ABI decoder before any
contract code runs, so an out-of-range type can never reach the log.

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

The target `cfid` used below is a real four-component counterfactual hash, computed with the
standard in the preimage:

```text
cfid = keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))
```

With the environment above, `boundAddress = 0x2222222222222222222222222222222222222222`, token id
`42`:

| Standard | Hash |
|---|---|
| `ERC721` (`uint8` 0) | `0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9` |
| `ERC1155` (`uint8` 1) | `0x14cfea274e2d2b7367bffaa93dbfdda489fd4fbed711f949a321a75789fdec44` |

The two rows differ only in the standard and produce different identities, which is why the standard
is in the preimage. These are the current values from `adapter-counterfactual-hashes.md`; that
document also lists three superseded cfid schemes, and an implementation reproducing any of those
for new hashes is behind. The identifier formula itself did not change when the cfid scheme did: the
target is opaque here, so the identifiers below moved only because their target moved.

## Identifier vectors

All vectors use the `ERC721` cfid `0x8493…15f9` above. `type` names a constant from the table.

| # | Caller | Type | Block | `variant` | `data` | `attestationId` |
|---|---|---|---|---|---|---|
| 1 | alice | `CONFIRM_ACCOUNT` (`1`) | `19000000` | `0` | empty | `0x7fde72c738899c71442073381b50194c322b2ea08732ae9b3ea121e57979b58d` |
| 2 | alice | `CONFIRM_ACCOUNT` (`1`) | `19000000` | `bytes32(1)` | empty | `0x579f37809a02f3f7fafa7ae9169874cb38d0bd965cc0474d6cafee7fa71c666d` |
| 3 | alice | `RATING` (`3`) | `19000000` | `0` | `0x57` | `0x68515a455383792a4087826ce399f87dc918b3a4ffc923470e5ce3fd1fee28d1` |
| 4 | bob | `CONFIRM_ACCOUNT` (`1`) | `19000000` | `0` | empty | `0x717e8cfdd3b3b7262f89dbdca8b077e972b2dc8e82ead73a2cb891ec4d76a30a` |
| 5 | alice | `CONFIRM_ACCOUNT` (`1`) | `19000001` | `0` | empty | `0xbd9c0f8e47f1feb43681b30583fae344e99d1b770c9cfe9ed8b4055f0546e9f4` |

> **These have now replaced two earlier sets.** The first set moved when the type stopped being a
> hash-named `bytes32`, whose raw 32 bytes `abi.encode` placed in the preimage, and became an enum,
> whose `uint8` sits right-aligned in a word. The second moved when the `extraData` discriminator
> left the cfid preimage, which changed the target rather than the formula. Both superseded sets are
> listed at the end of this document so an implementation can tell which one it reproduces.

Each pair of vectors pins one component's place in the formula. Vectors 1 and 2 differ only in
`variant`, 1 and 3 only in type and payload, 1 and 4 only in caller, 1 and 5 only in block.

```ts
import { encodeAbiParameters, keccak256 } from 'viem'
export function attestationId(
  adapterInteroperableAddress: `0x${string}`,
  attester: `0x${string}`,
  cfid: `0x${string}`,
  attestationType: number,
  blockNumber: bigint,
  variant: `0x${string}` = `0x${'00'.repeat(32)}`,
  data: `0x${string}` = '0x',
) {
  return keccak256(encodeAbiParameters(
    [{type:'bytes'}, {type:'address'}, {type:'bytes32'}, {type:'uint8'}, {type:'uint256'}, {type:'bytes32'}, {type:'bytes'}],
    [adapterInteroperableAddress, attester, cfid, attestationType, blockNumber, variant, data],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, any preimage with a leading
domain constant, the fields in any other order, a naked adapter address in place of the
Interoperable Address, the implementation address in place of the proxy, the transaction sender's
relayer or bundler in place of the calling account, and the superseded hash-named type below in
place of the enum's `uint8`. A target from any superseded cfid scheme also produces a different
identifier, which is what the second superseded table below records.

## Superseded: identifiers against the pre-removal cfid

Retained for identification only. Do not implement. Never deployed. These are the same five vectors
under the same formula, differing only in the target: they name the v0.0.17 pre-release cfid
`0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b`, which carried the reserved
`extraData` discriminator. Reproducing this table means your cfid derivation is behind, not your
identifier derivation.

| # | Superseded `attestationId` |
|---|---|
| 1 | `0xaf7980abec6ffd6f5d97df444510ce368dcbfcf7de185badd957b43a4fe8e105` |
| 2 | `0x9965d93cc49e1045bd26bffee741bc0182c227f5753af94bbcf5a3b0986a0455` |
| 3 | `0x76644bf03fd7b84cdc504cde53b335802d68ae53ea278033c9c42cb0807657df` |
| 4 | `0x35c0df33a0a54b1edd204dcee6109cf347492fd170950dddca74c0d392a4ee66` |
| 5 | `0xea933f7f114bd9eaedd2215c27110cc2892b27817c6159770705a33afedec6d5` |

## Superseded: hash-named `bytes32` types

Retained for identification only. Do not implement. Never deployed. Under this scheme the type was
an open 32-byte value, the keccak of a defining string, and `abi.encode` placed those raw bytes in
the preimage.

| Constant | Defining string | Value |
|---|---|---|
| `CONFIRM_ACCOUNT` | `adapter8004.attest.v1.confirm-account` | `0x0d1301b55a7106242fdc007f7371d46dbf2cef93819719bb571322d165ef0bdb` |
| `STAR` | `adapter8004.attest.v1.star` | `0xe57ebfd03b6f9111378311d8b209d3c35c5c9c45ce387029dbe32c0ff44b2651` |
| `RATING` | `adapter8004.attest.v1.rating` | `0xe29bafddb9bd210da3ccc8f60685504f8868bbcce6d9c216f35f0f841a6618b5` |
| `REVIEW` | `adapter8004.attest.v1.review` | `0x0ce439abec3b50d9bb4c1c26b71f5e02b7dac5a8f4546824b09b0066c94e6aed` |
| `INTERACTION` | `adapter8004.attest.v1.interaction` | `0x38bd7d6c19f392ef255c7033e6700c65ef16fc48f3ced5e18caf837f3231fedf` |

The identifiers those produced, in the environment of the table current at that time, which also
used the pre-removal cfid above:

| # | Superseded `attestationId` |
|---|---|
| 1 | `0x80d05e729b10ebc5c0852c919bcb47c18342bac827ab09e307827dd576332e67` |
| 2 | `0x97ff8f55126d26f62b78c5ec3b8908e1ab8bb76891d5e955832ab8cca1d0a202` |
| 3 | `0x127945db7ff1b8f34cfd587ee3605c33c70d686af9ae9081413fd0929a70f6de` |
| 4 | `0x1d000c7a6200f50086414eaab8e24343cca0a45518e82657ee5d652de28ebc87` |
| 5 | `0x3b3f23c978049fa900522abac43b368325b25936825ed83e402a4214e4ab762a` |

The `Attested` event signature moved with the type, from
`Attested(address,bytes32,bytes32,bytes32,bytes32,bytes)` to
`Attested(address,uint8,bytes32,bytes32,bytes32,bytes)`, so `topic0` differs too. Likewise `attest`,
from `attest(bytes32,bytes32,bytes32,bytes)` to `attest(uint8,bytes32,bytes32,bytes)`.

For any one adapter the two derivation schemes cannot collide by construction, because the identifier
preimage is always the longer of the two. Both carry the same adapter Interoperable Address and so
grow with it in step: writing `A` for that address padded up to a whole number of words and `D` for
the payload padded the same way, the four-component cfid encoding is `160 + A` bytes and this
encoding is `288 + A + D`, a gap of at least 128 bytes whatever the adapter address. For the EVM
adapter in the environment above the concrete figures are 192 bytes against 320. Stating the gap
rather than two fixed sizes matters, because neither size is fixed: the Solana namespace stress
adapter in `adapter-counterfactual-hashes.md` gives 224 and 352 instead, and the gap still holds.
