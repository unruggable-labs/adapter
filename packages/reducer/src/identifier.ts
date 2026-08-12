/**
 * The canonical subject-identifier grammar (spec I-2 / INV-2, decision D6).
 *
 * | Subject                                   | Identifier                              |
 * |-------------------------------------------|-----------------------------------------|
 * | The contract itself (CONTRACT/_OWNABLE)   | empty (`0x`)                            |
 * | Plain token (all five token standards)    | `0x00 || tokenId` (full-width 32 bytes) |
 * | Future kinds                              | `<kind byte >= 0x01> || kind layout`    |
 *
 * Encodings are canonical and permanent: token ids are always full-width (never
 * minimal-length), empty is reserved for the contract subject forever, and kind bytes are
 * append-only. An unknown kind byte names a distinct, opaque identity — never a re-encoding
 * of a known subject.
 */
import { concat, pad, toHex, type Hex } from 'viem'

export const CONTRACT_IDENTIFIER: Hex = '0x'
export const TOKEN_KIND_BYTE = 0x00

export type Subject =
  | { kind: 'contract' }
  | { kind: 'token'; tokenId: bigint }
  | { kind: 'unknown'; kindByte: number; raw: Hex }

/** Canonical token identifier: 0x00 kind byte + full-width 32-byte big-endian id (33 bytes). */
export function tokenIdentifier(tokenId: bigint): Hex {
  return concat(['0x00', pad(toHex(tokenId), { size: 32 })])
}

/** Decode an identifier into its subject. Rejects non-canonical token encodings (INV-2). */
export function decodeIdentifier(identifier: Hex): Subject {
  const body = identifier.slice(2)
  if (body.length === 0) return { kind: 'contract' }
  const kindByte = parseInt(body.slice(0, 2), 16)
  if (kindByte === TOKEN_KIND_BYTE) {
    if (body.length !== 66) {
      throw new Error(
        `non-canonical token identifier (${body.length / 2} bytes; must be exactly 33): ${identifier}`,
      )
    }
    return { kind: 'token', tokenId: BigInt(`0x${body.slice(2)}`) }
  }
  return { kind: 'unknown', kindByte, raw: identifier }
}

/** Human-readable identity alias used by the conformance fixtures ("addr:id" / "addr:contract"). */
export function identityAlias(tokenContract: string, identifier: Hex): string {
  const subject = decodeIdentifier(identifier)
  const contract = tokenContract.toLowerCase()
  if (subject.kind === 'contract') return `${contract}:contract`
  if (subject.kind === 'token') return `${contract}:${subject.tokenId}`
  return `${contract}:kind-${subject.kindByte}-${subject.raw}`
}
