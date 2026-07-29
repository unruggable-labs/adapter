# Adapter8004 v0.0.14 — ERC-7930 counterfactual hash fixture

Canonical formula:

```text
keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId))
```

Use ABI encoding for `(bytes,address,uint256)`, not packed encoding. The adapter is a full ERC-7930
Interoperable Address and is not hashed first. `tokenContract` is deliberately a naked EVM
`address`; do not encode it as an Interoperable Address. Chain binding comes from the adapter
Interoperable Address alone. For EVM, the adapter address is ERC-7930 v1 plus CAIP-350 `eip155`:

```text
uint16(1) || uint16(0) || uint8(referenceLength)
|| shortest-nonempty-big-endian(block.chainid) || uint8(20) || bytes20(account)
```

With adapter `0x1111111111111111111111111111111111111111`, token
`0x2222222222222222222222222222222222222222`, token ID `42`:

| Namespace | Adapter Interoperable Address | Naked token contract | Hash |
|---|---|---|---|
| Ethereum | `0x000100000101141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e` |
| Base | `0x00010000022105141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xd4f7e7c3e75d4d9c011d61c33666c7ba460bcb0a5964112643a31802fbf0791f` |
| Sepolia | `0x0001000003aa36a7141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xbd88f093e45b0adc6546b1363d8f876ac71cf52737abea2803edb5f938baeca5` |
| Solana namespace stress example | `0x000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111` | `0x2222222222222222222222222222222222222222` | `0xa992e5d61c04f1741eccdd005ea76b2584ec995dd010df8c3303afc4270614cc` |

The final row is an adapter-chain namespace stress vector; its illustrative adapter address is not
a native Solana CAIP-350 address.

```ts
import { encodeAbiParameters, keccak256 } from 'viem'
export function registrationHash(
  adapterInteroperableAddress: `0x${string}`,
  tokenContract: `0x${string}`,
  tokenId: bigint,
) {
  return keccak256(encodeAbiParameters(
    [{type:'bytes'}, {type:'address'}, {type:'uint256'}],
    [adapterInteroperableAddress, tokenContract, tokenId],
  ))
}
```

Negative vectors that MUST differ include `abi.encodePacked(...)`, the superseded
`abi.encode(chainIdentifier, adapter, tokenContract, tokenId)` candidate, a naked adapter address,
and any preimage that encodes `tokenContract` as an Interoperable Address.
