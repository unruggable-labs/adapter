/**
 * The reference reducer: the executable form of docs/spec/indexing.md.
 *
 * A pure fold from adapter events to identity state. Each branch cites the spec rule it
 * implements. Deliberately infrastructure-free: reorg handling (O-2) is the caller's job —
 * feed the canonical log, get the canonical state.
 */
import type { Hex } from 'viem'
import { decodeIdentifier, identityAlias } from './identifier.js'
import { interoperableAddress, registrationHash } from './hash.js'

export interface MetadataEntry {
  metadataKey: string
  metadataValue: Hex
}

/** Adapter event as the reducer consumes it (decoded log or conformance-fixture entry). */
export interface AdapterEvent {
  block: number
  logIndex: number
  event: string
  args: Record<string, unknown>
}

export interface IdentityState {
  registered: boolean
  standard: string | null
  agentURI: string | null
  metadata: Record<string, Hex>
  agentWallet: string | null
}

interface InternalIdentity extends IdentityState {
  tokenContract: string
  identifier: Hex
  /** R-5 tracking: has any owner-authored event been observed for this identity? */
  sawOwnerAuthored: boolean
  /** R-7 tracking: has any contract-authored event been observed for this identity? */
  sawContractAuthored: boolean
}

export interface ReducedState {
  /** Keyed by human-readable identity alias ("tokenContract:tokenId" / "tokenContract:contract"). */
  identities: Record<string, IdentityState>
  /** Full ERC-8004 projection: account -> registry agent id (decimal string). P-1/P-3. */
  primaryAgents: Record<string, string>
  /** Counterfactual projection: account -> identity alias. P-1. */
  primaryCounterfactualAgents: Record<string, string>
}

const COUNTERFACTUAL_EVENTS = new Set([
  'CounterfactualAgentRegistered',
  'CounterfactualAgentURISet',
  'CounterfactualMetadataSet',
  'CounterfactualMetadataBatchSet',
  'CounterfactualAgentWalletSet',
  'CounterfactualAgentWalletUnset',
])

/** Events that are provenance only and MUST NOT be applied as state transitions (P-2). */
const PROVENANCE_EVENTS = new Set(['PrimaryAgentSetWithSig', 'PrimaryAgentClearedWithSig'])

/** Full-registration events: never part of the counterfactual projection (D2, spec section 7). */
const FULL_SYSTEM_EVENTS = new Set([
  'AgentBound',
  'AgentURISet',
  'MetadataSet',
  'MetadataBatchSet',
  'AgentWalletSet',
  'AgentWalletUnset',
  'BindingMetadataRewritten',
  'IdentityRegistryUpdated',
])

export function reduce(
  events: AdapterEvent[],
  context: { chainId: bigint; adapter: string },
): ReducedState {
  // O-1: total order by (blockNumber, logIndex). Fixtures arrive sorted; real logs may not.
  const ordered = [...events].sort((a, b) => a.block - b.block || a.logIndex - b.logIndex)

  const adapterIA = interoperableAddress(context.chainId, context.adapter as `0x${string}`)
  const identities = new Map<Hex, InternalIdentity>()
  const primaryAgents: Record<string, string> = {}
  const primaryCounterfactualAgents: Record<string, string> = {}

  for (const ev of ordered) {
    if (PROVENANCE_EVENTS.has(ev.event)) continue // P-2
    if (FULL_SYSTEM_EVENTS.has(ev.event)) continue // D2: independent system

    if (ev.event === 'PrimaryAgentSet') {
      // P-1/P-3: agent id 0 is a real id; "unset" is only the absence of a row.
      primaryAgents[String(ev.args.account).toLowerCase()] = String(ev.args.agentId)
      continue
    }
    if (ev.event === 'PrimaryAgentCleared') {
      delete primaryAgents[String(ev.args.account).toLowerCase()]
      continue
    }
    if (ev.event === 'PrimaryCounterfactualAgentSet') {
      primaryCounterfactualAgents[String(ev.args.account).toLowerCase()] = identityAlias(
        String(ev.args.tokenContract),
        ev.args.identifier as Hex,
      )
      continue
    }
    if (ev.event === 'PrimaryCounterfactualAgentCleared') {
      delete primaryCounterfactualAgents[String(ev.args.account).toLowerCase()]
      continue
    }

    if (!COUNTERFACTUAL_EVENTS.has(ev.event)) {
      throw new Error(`unknown event: ${ev.event}`)
    }

    const tokenContract = String(ev.args.tokenContract)
    const identifier = ev.args.identifier as Hex
    const emitter = String(ev.args.emitter)
    const subject = decodeIdentifier(identifier)

    // I-1/I-2: the identity IS the hash; coordinates are attributes.
    const hash = registrationHash(adapterIA, tokenContract as `0x${string}`, identifier)

    let identity = identities.get(hash)
    if (!identity) {
      identity = {
        tokenContract,
        identifier,
        registered: false,
        standard: null,
        agentURI: null,
        metadata: {},
        agentWallet: null,
        sawOwnerAuthored: false,
        sawContractAuthored: false,
      }
      identities.set(hash, identity)
    }

    // R-4: classification by the emitter alone.
    const contractAuthored = emitter.toLowerCase() === tokenContract.toLowerCase()

    // R-5 (token subjects): contract authority is valid only before the first owner-authored
    // event — later contract-authored events are post-burn or spoofing and are ignored.
    const demotedByR5 = subject.kind !== 'contract' && contractAuthored && identity.sawOwnerAuthored
    // R-7 (contract subjects): owner authority is valid only before the contract's first
    // utterance — a stale or hostile owner() key never supersedes the contract itself.
    const demotedByR7 = subject.kind === 'contract' && !contractAuthored && identity.sawContractAuthored

    if (contractAuthored) identity.sawContractAuthored = true
    else identity.sawOwnerAuthored = true

    if (demotedByR5 || demotedByR7) continue

    switch (ev.event) {
      case 'CounterfactualAgentRegistered': {
        // R-1: a registration is a full re-statement — it resets URI, metadata, and standard.
        identity.registered = true
        identity.standard = String(ev.args.standard)
        identity.agentURI = String(ev.args.agentURI)
        identity.metadata = {}
        for (const entry of ev.args.metadata as MetadataEntry[]) {
          identity.metadata[entry.metadataKey] = entry.metadataValue
        }
        break
      }
      // R-2: field events touch their field alone, and apply even before any registration.
      case 'CounterfactualAgentURISet':
        identity.agentURI = String(ev.args.newURI)
        break
      case 'CounterfactualMetadataSet':
        identity.metadata[String(ev.args.metadataKey)] = ev.args.metadataValue as Hex
        break
      case 'CounterfactualMetadataBatchSet':
        for (const entry of ev.args.metadata as MetadataEntry[]) {
          identity.metadata[entry.metadataKey] = entry.metadataValue
        }
        break
      case 'CounterfactualAgentWalletSet':
        identity.agentWallet = String(ev.args.newWallet).toLowerCase()
        break
      case 'CounterfactualAgentWalletUnset':
        identity.agentWallet = null
        break
    }
  }

  // Report through human-readable aliases; internal keying was by hash (I-1). R-2 (OPEN-2):
  // unregistered identities are surfaced, never hidden — consumers filter on `registered`.
  const reported: Record<string, IdentityState> = {}
  for (const identity of identities.values()) {
    reported[identityAlias(identity.tokenContract, identity.identifier)] = {
      registered: identity.registered,
      standard: identity.standard,
      agentURI: identity.agentURI,
      metadata: identity.metadata,
      agentWallet: identity.agentWallet,
    }
  }
  return { identities: reported, primaryAgents, primaryCounterfactualAgents }
}
