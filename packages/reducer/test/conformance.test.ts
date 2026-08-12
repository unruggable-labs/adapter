/**
 * Conformance harness: every fixture in docs/spec/fixtures is one test. The reducer must
 * reproduce each fixture's `expected` block exactly (after address-case normalization —
 * addresses compare case-insensitively; URIs, keys, and hex payloads compare byte-exactly).
 */
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { reduce, type AdapterEvent } from '../src/index.js'

const FIXTURES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../../docs/spec/fixtures')

interface Fixture {
  name: string
  spec: string[]
  description: string
  chainId: number
  adapter: string
  events: AdapterEvent[]
  expected: {
    identities: Record<string, unknown>
    primaryAgents: Record<string, string>
    primaryCounterfactualAgents: Record<string, string>
  }
}

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/
/** Identity alias: "0xAddr:decimal" or "0xAddr:contract" — normalize the address part. */
const ALIAS_RE = /^(0x[0-9a-fA-F]{40}):(.+)$/

function normalizeValue(value: unknown): unknown {
  if (typeof value === 'string') {
    if (ADDRESS_RE.test(value)) return value.toLowerCase()
    const alias = ALIAS_RE.exec(value)
    if (alias) return `${alias[1]!.toLowerCase()}:${alias[2]}`
    return value
  }
  if (Array.isArray(value)) return value.map(normalizeValue)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const alias = ALIAS_RE.exec(k)
      const key = alias
        ? `${alias[1]!.toLowerCase()}:${alias[2]}`
        : ADDRESS_RE.test(k)
          ? k.toLowerCase()
          : k
      out[key] = normalizeValue(v)
    }
    return out
  }
  return value
}

const files = readdirSync(FIXTURES_DIR)
  .filter((f) => f.endsWith('.json'))
  .sort()

describe('conformance fixtures', () => {
  it('finds the fixture set', () => {
    expect(files.length).toBeGreaterThanOrEqual(13)
  })

  for (const file of files) {
    const fixture: Fixture = JSON.parse(readFileSync(join(FIXTURES_DIR, file), 'utf8'))
    it(`${fixture.name} [${fixture.spec.join(', ')}]`, () => {
      const actual = reduce(fixture.events, {
        chainId: BigInt(fixture.chainId),
        adapter: fixture.adapter,
      })
      expect(normalizeValue(actual)).toEqual(normalizeValue(fixture.expected))
    })
  }
})
