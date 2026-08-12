# Conformance fixtures

Each `*.json` file is one conformance case for the indexing spec
([`../indexing.md`](../indexing.md)): a sequence of adapter events plus the required end state.
A conforming reducer replays `events` in the order given (already sorted by
`(block, logIndex)`, rule O-1) and MUST reproduce `expected` exactly.

## Schema

```jsonc
{
  "name": "kebab-case-id",
  "spec": ["R-1", "R-5"],            // rules exercised
  "description": "what this proves",
  "chainId": 11155111,
  "adapter": "0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92",
  "events": [
    {
      "block": 100, "logIndex": 0,
      "event": "CounterfactualAgentRegistered",   // exact event name
      "args": { /* named args, ABI order */ }
    }
  ],
  "expected": {
    // Counterfactual identities. Token subjects are keyed "tokenContract:tokenId"; contract
    // subjects (empty identifier) are keyed "tokenContract:contract". These keys are
    // human-readable aliases: reducers MUST key internally on the registrationHash derived per
    // I-2 from (chainId, adapter, tokenContract, identifier) and only report through these keys.
    "identities": {
      "0xToken…:1": {
        "registered": true,
        "standard": "ERC721",              // enum name; null until a registration event (R-2)
        "agentURI": "ipfs://…",            // or null
        "metadata": { "key": "0x…" },      // hex values; {} when empty
        "agentWallet": "0x…"               // or null
      }
    },
    "primaryAgents": { "0xAccount…": "0" },              // uint256 as decimal string; absent == unset
    "primaryCounterfactualAgents": { "0xAccount…": "0xToken…:1" }  // identity key; absent == unset
  }
}
```

Conventions: addresses are checksummed 20-byte hex; `metadata` values are `0x`-hex bytes; the
`identifier` in every counterfactual event's args is the canonical subject identifier exactly as
emitted (`"0x"` empty for contract subjects, `0x00 ‖ 32-byte id` for tokens) — reducers MUST
verify it reproduces the event's hash (I-2) and derive the identity from it; the
`registrationHash` topic itself is omitted from `args` as derivable. An identity absent from
`expected.identities` MUST have no state (no events, or all its events ignored per R-5/R-7).
Fixtures never include pre-cutover legacy events (§8).

## Current set

| Fixture | Rules |
|---|---|
| `basic-register.json` | I-1, R-1 |
| `latest-wins-and-same-block.json` | R-3, O-1 |
| `reregistration-resets.json` | R-1 |
| `field-events-and-wallet-unset.json` | R-2 |
| `collection-premint-then-owner.json` | R-4, R-5 (window closes) |
| `burn-reopen-hijack-demoted.json` | R-5 (D3 core case) |
| `collection-only-authority.json` | R-5 (no owner event ever) |
| `contract-binding-exempt.json` | R-6, R-7 |
| `contract-senior-subordination.json` | R-7 (D6: stale owner() demoted) |
| `subject-split.json` | I-2, R-6 (distinct identities at one coordinate) |
| `full-cf-independence.json` | §7 (D2) |
| `primary-agent-projections.json` | P-1, P-2, P-3 |
| `unregistered-field-events.json` | R-2 (OPEN-2: surfaced with `registered: false`) |
