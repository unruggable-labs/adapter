# Proposal: Separate reverse-resolution systems for ERC-8004 vs counterfactual

**Status:** proposal (product intent; implementation plan TBD)  
**Target release:** `0.0.14` (bundle with primary-system split)  
**Repo:** `/Users/nxt3d/projects/adapter`  
**Touches:** primary-agent reverse resolution (`IERC8004AdapterPrimaryAgent`, `Adapter8004` storage/API); counterfactual `registrationHash` domain  
**Related:** ownerless CF registration (`0.0.13` work) is independent and can ship first; `0.0.14` is the reverse-resolution split **plus** ERC-7930 chain binding for CF hashes

## Problem

Adapter8004 currently has **one** reverse-resolution mapping: `address => bytes32` primary agent id (`_primaryAgent` / `primaryAgentOf`). That single namespace is overloaded to hold either:

1. a real ERC-8004 **`agentId`** (from full registry `register` / `bindExisting` / `registerAndSetPrimary`), or  
2. a counterfactual **`registrationHash`** (from the unsigned CF register family)

Those are different identity systems. A full 8004 registration mints (or binds) an on-chain registry NFT owned by the adapter. A counterfactual registration is emit-only and keyed by `(interoperableAddress(adapter), tokenContract, tokenId)`. Collapsing both into one `primaryAgentOf(address)` forces consumers to guess which kind of id they received, and prevents an account from having a clear primary in **each** system at once.

Product intent: treat **full ERC-8004** and **counterfactual ERC-8004** as two completely separate systems — including reverse resolution.

## Solution

Maintain **two separate reverse-resolution mappings** (and matching APIs / events):

| System | Stored id meaning | Example setter / getter direction |
|---|---|---|
| Full ERC-8004 | registry `agentId` as `bytes32` (or `uint256` if preferred) | address → on-chain agent id |
| Counterfactual | `registrationHash` | address → CF registration hash |

An account may set, clear, and resolve each independently. Setting a CF primary must not overwrite or clear the full-8004 primary, and vice versa. Indexers and wallets that care about one system should not have to filter a mixed namespace.

### Locked product rules

1. **Two mappings, two read paths** — e.g. conceptually `primaryAgentOf(account)` for full 8004 and `primaryCounterfactualAgentOf(account)` (names TBD in the plan) for CF. Do not overload a single getter.
2. **Two write surfaces** — direct/paid set/clear for each system; signed (gasless) set/clear remains full-8004-only, so CF and full-8004 cannot cross-write.
3. **Convenience helpers stay typed** — `registerAndSetPrimary` wires only the full-8004 mapping;
   counterfactual primary setters wire only the CF mapping.
4. **No shared “which kind is this bytes32?” bit** inside one slot — separation is structural, not a tagged union in one mapping.
5. **Existing complement / unset-sentinel design** may be reused per mapping if still sound; each mapping needs its own unset semantics.
6. **Upgrade must be planned carefully** — current live/source data in `_primaryAgent` may already mix both id kinds. The plan must say how to migrate, dual-read, or break cleanly for `0.0.14`.
7. **Counterfactual `registrationHash` MUST bind the adapter proxy through its full ERC-7930
   Interoperable Address and MUST keep `tokenContract` as a naked EVM `address`.** Do not encode
   `tokenContract` as an Interoperable Address. Chain binding comes from the adapter Interoperable
   Address alone.

### Counterfactual hash domain (ERC-7930) — locked for `0.0.14`

Today the domain is approximately:

```solidity
keccak256(abi.encode(block.chainid, address(adapter), tokenContract, tokenId))
```

That only distinguishes EVM numeric chain ids. Collisions / ambiguity across chain *types* remain possible in a multi-ecosystem indexer world.

**Required change in `0.0.14`:** encode the adapter proxy as a full
**[ERC-7930](https://eips.ethereum.org/EIPS/eip-7930) Interoperable Address** (local chain plus
AddressLength `20` plus the raw EVM address), then hash that dynamic byte string with the naked
`tokenContract` address and `tokenId` using `abi.encode(bytes,address,uint256)`. Keep a
zero-AddressLength Chain Identifier helper if useful.

Intent:

- Adapter deployments in different chain namespaces must not share a hash namespace.
- EVM deployments still derive the Chain Identifier from the local chain via the CAIP-350 / ERC-7930 profile for `eip155` (or equivalent), rather than hashing raw `block.chainid` alone.
- This is a **deliberate hard break** of existing CF `registrationHash` values and fits the already-planned `0.0.14` ABI/hash cutover. Do not keep a dual-hash compatibility shim unless the plan finds a compelling reason.

### Non-goals

- Merging CF identities into the ERC-8004 registry  
- Preserving pre-`0.0.14` `registrationHash` values that used bare `block.chainid`  
- Forcing every collection to use both reverse-resolution systems  
- Collapsing back to one mapping with a discriminant flag as the long-term model  
- Shipping ERC-7930 as a separate later release after the primary split — **bundle both in `0.0.14`**

## Open points for the implementation plan

Resolve with concrete recommendations:

1. **API naming** — keep `primaryAgentOf` for full 8004 only, or rename both for clarity; deprecate path for old mixed reads.
2. **Migration** — what happens to existing `_primaryAgent` entries that may already store CF hashes vs agent ids? Heuristic split, wipe, dual-write period, or hard break?
3. **Events** — split event families vs tagged events; indexer migration notes.
4. **Auth model** — do both systems keep the same account-self / owner-admin / EIP-712 rules?
5. **Storage layout** — new slot for the second mapping; retain only the full-system signed nonce stream.
6. **Docs / fixtures** — README, CHANGELOG, `docs/fixtures/adapter-primaryagent-withsig.md`, interface NatSpec.
7. **Tests** — an account can hold both primaries; cross-system set does not clobber; combined register helpers write the correct map only; full-system signed replay/nonce behavior after the split.
8. **ERC-7930 encoding** — exact on-chain representation of the Chain Identifier in the hash preimage (`bytes` vs fixed buffer); how EVM adapters obtain it (pure helper from `block.chainid`, immutable constructor arg, or view); CAIP-350 `eip155` profile details; whether `registrationHash` gains an overload that accepts an explicit chain identifier for off-chain tooling; test vectors for mainnet/Base/Sepolia and at least one documented non-EVM chain-id example for indexer clarity.

## Acceptance sketch

- Full-8004 reverse resolve and CF reverse resolve are independent.
- Consumers never receive an ambiguous `bytes32` from a single mixed getter.
- Register-and-set-primary helpers cannot write the wrong system’s mapping.
- Upgrade/migration story is explicit and tested.
- Counterfactual `registrationHash` incorporates the full ERC-7930 Interoperable Address of the
  adapter and the naked EVM token-contract address; identical token coordinates under different
  adapter chain types do not collide; docs and tests show the new domain.

## History

Product discussion 2026-07-29: “two completely separate systems, 8004 and counterfactual 8004,” including two reverse-resolution mappings (address → agent id).  
Follow-up 2026-07-29: CF hashes must use ERC-7930 Chain Identifiers instead of bare EVM chain ids; ship in `0.0.14` with the primary split.
Superseded refinement 2026-07-29: encode both the adapter and token contract as full ERC-7930
Interoperable Addresses.
Final locked correction 2026-07-29: encode only the adapter proxy as a full ERC-7930 Interoperable
Address and hash `abi.encode(adapterIA, tokenContract, tokenId)`; `tokenContract` remains a naked
EVM address and chain binding comes from `adapterIA` alone.
