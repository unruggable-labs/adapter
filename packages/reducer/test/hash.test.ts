/**
 * Pins the off-chain encoding against the published vectors in
 * docs/fixtures/adapter-counterfactual-hashes.md (which the Solidity suite pins on-chain, so
 * the two implementations are anchored to the same literals).
 */
import { describe, expect, it } from 'vitest'
import { chainIdentifier, interoperableAddress, registrationHash } from '../src/hash.js'
import { tokenIdentifier, CONTRACT_IDENTIFIER, decodeIdentifier } from '../src/identifier.js'

const ADAPTER = '0x1111111111111111111111111111111111111111' as const
const TOKEN = '0x2222222222222222222222222222222222222222' as const

describe('ERC-7930 v1 encoding (D1 revised)', () => {
  it('chain identifiers match the published table', () => {
    expect(chainIdentifier(1n)).toBe('0x00010000010100')
    expect(chainIdentifier(8453n)).toBe('0x0001000002210500')
    expect(chainIdentifier(11155111n)).toBe('0x0001000003aa36a700')
  })

  it('interoperable addresses match the published table', () => {
    expect(interoperableAddress(1n, ADAPTER)).toBe(
      '0x000100000101141111111111111111111111111111111111111111',
    )
  })
})

describe('registrationHash vectors', () => {
  const mainnetIA = interoperableAddress(1n, ADAPTER)

  it('token subject, id 42', () => {
    expect(registrationHash(mainnetIA, TOKEN, tokenIdentifier(42n))).toBe(
      '0x2561a5127ce57aca2b3435b4ed6ed64f7c5b6751cfdc446b966689526719a6b2',
    )
  })

  it('contract subject (empty identifier)', () => {
    expect(registrationHash(mainnetIA, TOKEN, CONTRACT_IDENTIFIER)).toBe(
      '0x7bcd28a8ab06672398163fa398bb414db0be5439508f0e96f7dd440cf2c43ea0',
    )
  })

  it('token id 0 is distinct from the contract subject', () => {
    expect(registrationHash(mainnetIA, TOKEN, tokenIdentifier(0n))).toBe(
      '0x7e90bedaa189d8b5124fb6e56be1140283a8a16451546607fe0d42b892a2a2a8',
    )
  })
})

describe('identifier grammar (INV-2)', () => {
  it('token identifiers are full-width 33 bytes and round-trip', () => {
    expect(tokenIdentifier(42n)).toBe(
      '0x00000000000000000000000000000000000000000000000000000000000000002a',
    )
    expect(decodeIdentifier(tokenIdentifier(0n))).toEqual({ kind: 'token', tokenId: 0n })
    expect(decodeIdentifier(tokenIdentifier(2n ** 256n - 1n))).toEqual({
      kind: 'token',
      tokenId: 2n ** 256n - 1n,
    })
  })

  it('empty means the contract subject; unknown kind bytes are opaque distinct subjects', () => {
    expect(decodeIdentifier('0x')).toEqual({ kind: 'contract' })
    expect(decodeIdentifier('0x01ff')).toMatchObject({ kind: 'unknown', kindByte: 1 })
  })

  it('non-canonical (minimal-length) token identifiers are rejected', () => {
    expect(() => decodeIdentifier('0x002a')).toThrow(/non-canonical/)
  })
})
