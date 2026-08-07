# Adapter8004 v0.0.15 — ERC-7930 counterfactual hash fixture

Canonical formula:

```text
keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId, extraData))
```

> **Scheme revision, v0.0.15.** A trailing `bytes32 extraData` was appended to the preimage, so
> every hash below changed. The superseded values are retained at the end of this document so that a
> reimplementer can tell which scheme their output matches. `extraData` is `bytes32(0)` in this
> implementation and no caller can supply it, because it is a compile-time constant rather than an
> argument. Read its value from the `extraData` field now emitted on every counterfactual event.

**Identity.** The identity is the `registrationHash`. Each token has exactly one identity, but
`(tokenContract, tokenId)` is not considered a unique identifier, because one contract may have more
than one set of ids. An example is a contract with classes of ids, where Class A id 1 and Class B
id 1 are different tokens. `extraData` is what separates them, so key on the `registrationHash` and
do not collapse rows by `(tokenContract, tokenId)`.

Use ABI encoding for `(bytes,address,uint256,bytes32)`, not packed encoding. The adapter is a full
ERC-7930 Interoperable Address and is not hashed first. `tokenContract` is deliberately a naked EVM
`address`; do not encode it as an Interoperable Address. Chain binding comes from the adapter
Interoperable Address alone. For EVM, the adapter address is ERC-7930 v1 plus CAIP-350 `eip155`:

```text
uint16(1) || uint16(0) || uint8(referenceLength)
|| shortest-nonempty-big-endian(block.chainid) || uint8(20) || bytes20(account)
```

With adapter `0x1111111111111111111111111111111111111111`, token
`0x2222222222222222222222222222222222222222`, token ID `42`, `extraData = bytes32(0)`:

| Namespace | Adapter Interoperable Address | Naked token contract | Hash |
|---|---|---|---|
| Ethereum | `0x000100000101141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf` |
| Base | `0x00010000022105141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xaddf435e3042b0f79ee2a2c26e5ec3a7757b2fec663ca0f45547b09489d0e07e` |
| Sepolia | `0x0001000003aa36a7141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x5546dad5cfa9e0c3df6dff6ebca6d72e8bc3d707f2827c81e708a615cd24a2cb` |
| Solana namespace stress example | `0x000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x725203cd24b34d707d2e8e9ae2dd74c7ea01e0cead262b4fe5fb483345c4d0d1` |

The final row is an adapter-chain namespace stress vector; its illustrative adapter address is not
a native Solana CAIP-350 address.

```ts
import { encodeAbiParameters, keccak256 } from 'viem'
export function registrationHash(
  adapterInteroperableAddress: `0x${string}`,
  tokenContract: `0x${string}`,
  tokenId: bigint,
  extraData: `0x${string}` = `0x${'00'.repeat(32)}`,
) {
  return keccak256(encodeAbiParameters(
    [{type:'bytes'}, {type:'address'}, {type:'uint256'}, {type:'bytes32'}],
    [adapterInteroperableAddress, tokenContract, tokenId, extraData],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, the superseded pre-v0.0.15
preimage, the same fields with `extraData` leading rather than trailing, a different `extraData`
value, the superseded `abi.encode(chainIdentifier, adapter, tokenContract, tokenId)` candidate, a
naked adapter address, and any preimage that encodes `tokenContract` as an Interoperable Address.

## Superseded: pre-v0.0.15 scheme (no `extraData`)

Retained for identification only. Do not implement.

```text
keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId))
```

Same inputs as above (adapter `0x1111…1111`, token `0x2222…2222`, token ID `42`):

| Namespace | Superseded hash |
|---|---|
| Ethereum | `0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e` |
| Base | `0xd4f7e7c3e75d4d9c011d61c33666c7ba460bcb0a5964112643a31802fbf0791f` |
| Sepolia | `0xbd88f093e45b0adc6546b1363d8f876ac71cf52737abea2803edb5f938baeca5` |
| Solana namespace stress example | `0xa992e5d61c04f1741eccdd005ea76b2584ec995dd010df8c3303afc4270614cc` |

If your implementation reproduces this table, you are on the superseded scheme. Append `extraData`
as a trailing `bytes32` to move to the current one.

The counterfactual event signatures also changed in v0.0.15. Every event gained a non-indexed
`bytes32 extraData`, and the former `uint8 version` field was removed because `topic0` is the
keccak of the full signature and already discriminates schema on its own. As a result `topic0` moved
for all six counterfactual events and for `PrimaryCounterfactualAgentSet`, so an indexer must cut
over to the new ABI at the same time.
