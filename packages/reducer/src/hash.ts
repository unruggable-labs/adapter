/**
 * The canonical counterfactual identity (spec I-2, decisions D1-revised and D6):
 *
 *   registrationHash = keccak256(abi.encode(adapterInteroperableAddress, tokenContract, identifier))
 *
 * The adapter bytes are the standard ERC-7930 v1 Interoperable Address (version bytes
 * included), frozen at version 0x0001 in the preimage permanently (INV-1). Vectors:
 * docs/fixtures/adapter-counterfactual-hashes.md.
 */
import { concat, encodeAbiParameters, keccak256, toHex, type Address, type Hex } from 'viem'

/** Minimal big-endian chain reference (ERC-7930 shortest-non-empty rule). */
function chainReference(chainId: bigint): Hex {
  if (chainId === 0n) throw new Error('chainId 0 is invalid')
  let hex = chainId.toString(16)
  if (hex.length % 2 === 1) hex = `0${hex}`
  return `0x${hex}`
}

/** ERC-7930 v1 Chain Identifier (eip155 profile): 0x0001 || 0x0000 || refLen || ref || 0x00. */
export function chainIdentifier(chainId: bigint): Hex {
  const ref = chainReference(chainId)
  const refLen = (ref.length - 2) / 2
  return concat(['0x00010000', toHex(refLen, { size: 1 }), ref, '0x00'])
}

/** Full ERC-7930 v1 Interoperable Address: chain envelope + AddressLength 0x14 + raw address. */
export function interoperableAddress(chainId: bigint, account: Address): Hex {
  const ref = chainReference(chainId)
  const refLen = (ref.length - 2) / 2
  return concat(['0x00010000', toHex(refLen, { size: 1 }), ref, '0x14', account])
}

/** The one preimage for every subject kind. `identifier` is '0x' for the contract subject. */
export function registrationHash(
  adapterInteroperableAddress: Hex,
  tokenContract: Address,
  identifier: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes' }, { type: 'address' }, { type: 'bytes' }],
      [adapterInteroperableAddress, tokenContract, identifier],
    ),
  )
}
