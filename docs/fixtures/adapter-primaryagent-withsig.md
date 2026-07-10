# Adapter8004 v0.0.11 — signed primary-agent consumer fixture

Source of truth for consumers (Dappa) of the gasless primary-agent surface. Do **not** hand-maintain
a separate schema — this fixture and the generated ABI are authoritative.

All three signed methods are **account-self**: the signature is verified against `account` (EOA
`ecrecover`, or the account's ERC-1271 policy). Fetch `nonces(account)` immediately before signing;
the nonce is embedded in the signed struct, not passed as calldata. `deadline` is capped at **30
minutes** ahead of the current block timestamp (a deadline equal to it is still valid). A used
signature is never retried — a stale signature is a refresh-and-resign.

## EIP-712 domain

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
```

- `name`:  `"Adapter8004"`
- `version`: `"1"`
- `chainId`: the connected chain id
- `verifyingContract`: the **adapter proxy** address (allowlisted per chain)

No cached separator; the separator is recomputed on-chain from `block.chainid` and `address(this)`,
so a signature is bound to one proxy and one chain.

## EIP-712 type strings (exact `encodeType`)

```
SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)
ClearPrimaryAgent(address account,uint256 nonce,uint256 deadline)
CounterfactualRegisterAndSetPrimary(uint8 standard,address tokenContract,uint256 tokenId,string agentURI,MetadataEntry[] metadata,address agentWallet,address signer,uint256 nonce,uint256 deadline)MetadataEntry(string metadataKey,bytes metadataValue)
```

`nonce` is `nonces(account)` for set/clear and `nonces(signer)` for the combined call. The combined
call takes no independent `agentId`: the primary id is the derived
`registrationHash = keccak256(abi.encode(chainId, proxy, tokenContract, tokenId))`, which is also the
return value. `metadata` is hashed per the EIP-712 array rule (empty array hashes to `keccak256("")`).

## viem — typed data

```ts
import { createWalletClient, custom, encodeFunctionData } from 'viem'

const domain = {
  name: 'Adapter8004',
  version: '1',
  chainId, // number
  verifyingContract: ADAPTER_PROXY, // 0x...
} as const

// ---- setPrimaryAgentWithSig ----
const nonce = await publicClient.readContract({
  address: ADAPTER_PROXY, abi: adapterAbi, functionName: 'nonces', args: [account],
})
const deadline = BigInt(Math.floor(Date.now() / 1000) + 5 * 60) // 5-minute frontend default

const setTypes = {
  SetPrimaryAgent: [
    { name: 'account', type: 'address' },
    { name: 'agentId', type: 'bytes32' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const

const setSignature = await walletClient.signTypedData({
  account, domain, types: setTypes, primaryType: 'SetPrimaryAgent',
  message: { account, agentId, nonce, deadline },
})

const setCalldata = encodeFunctionData({
  abi: adapterAbi, functionName: 'setPrimaryAgentWithSig',
  args: [account, agentId, deadline, setSignature],
})
// relayer broadcasts { to: ADAPTER_PROXY, data: setCalldata }

// ---- counterfactualRegisterAndSetPrimaryWithSig (combined, one signer) ----
const combinedTypes = {
  CounterfactualRegisterAndSetPrimary: [
    { name: 'standard', type: 'uint8' },
    { name: 'tokenContract', type: 'address' },
    { name: 'tokenId', type: 'uint256' },
    { name: 'agentURI', type: 'string' },
    { name: 'metadata', type: 'MetadataEntry[]' },
    { name: 'agentWallet', type: 'address' },
    { name: 'signer', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
  MetadataEntry: [
    { name: 'metadataKey', type: 'string' },
    { name: 'metadataValue', type: 'bytes' },
  ],
} as const

const combinedNonce = await publicClient.readContract({
  address: ADAPTER_PROXY, abi: adapterAbi, functionName: 'nonces', args: [signer],
})
const combinedSignature = await walletClient.signTypedData({
  account: signer, domain, types: combinedTypes, primaryType: 'CounterfactualRegisterAndSetPrimary',
  message: {
    standard, tokenContract, tokenId, agentURI, metadata, agentWallet, signer,
    nonce: combinedNonce, deadline,
  },
})
const combinedCalldata = encodeFunctionData({
  abi: adapterAbi, functionName: 'counterfactualRegisterAndSetPrimaryWithSig',
  args: [standard, tokenContract, tokenId, agentURI, metadata, agentWallet, signer, deadline, combinedSignature],
})
// The client derives the primary hash to display from the token coordinates:
// registrationHash = keccak256(abi.encode(chainId, proxy, tokenContract, tokenId))
```

`clearPrimaryAgentWithSig` is identical to the set flow with `ClearPrimaryAgent(address account,
uint256 nonce,uint256 deadline)` and `args: [account, deadline, signature]`.

## Generated ABI fragment (functions + audit events)

```json
[
  { "type": "function", "name": "setPrimaryAgentWithSig", "stateMutability": "nonpayable",
    "inputs": [
      { "name": "account", "type": "address" },
      { "name": "agentId", "type": "bytes32" },
      { "name": "deadline", "type": "uint256" },
      { "name": "signature", "type": "bytes" }
    ], "outputs": [] },
  { "type": "function", "name": "clearPrimaryAgentWithSig", "stateMutability": "nonpayable",
    "inputs": [
      { "name": "account", "type": "address" },
      { "name": "deadline", "type": "uint256" },
      { "name": "signature", "type": "bytes" }
    ], "outputs": [] },
  { "type": "function", "name": "counterfactualRegisterAndSetPrimaryWithSig", "stateMutability": "nonpayable",
    "inputs": [
      { "name": "standard", "type": "uint8" },
      { "name": "tokenContract", "type": "address" },
      { "name": "tokenId", "type": "uint256" },
      { "name": "agentURI", "type": "string" },
      { "name": "metadata", "type": "tuple[]",
        "components": [
          { "name": "metadataKey", "type": "string" },
          { "name": "metadataValue", "type": "bytes" }
        ] },
      { "name": "agentWallet", "type": "address" },
      { "name": "signer", "type": "address" },
      { "name": "deadline", "type": "uint256" },
      { "name": "signature", "type": "bytes" }
    ],
    "outputs": [ { "name": "computedHash", "type": "bytes32" } ] },
  { "type": "function", "name": "nonces", "stateMutability": "view",
    "inputs": [ { "name": "account", "type": "address" } ],
    "outputs": [ { "name": "nonce", "type": "uint256" } ] },
  { "type": "event", "name": "PrimaryAgentSetWithSig", "anonymous": false,
    "inputs": [
      { "name": "account", "type": "address", "indexed": true },
      { "name": "agentId", "type": "bytes32", "indexed": true },
      { "name": "relayer", "type": "address", "indexed": true },
      { "name": "nonce", "type": "uint256", "indexed": false }
    ] },
  { "type": "event", "name": "PrimaryAgentClearedWithSig", "anonymous": false,
    "inputs": [
      { "name": "account", "type": "address", "indexed": true },
      { "name": "relayer", "type": "address", "indexed": true },
      { "name": "nonce", "type": "uint256", "indexed": false }
    ] }
]
```

## Deterministic digest fixture (for cross-implementation checks)

For a `SetPrimaryAgent` digest:

```
domainSeparator = keccak256(abi.encode(
  keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
  keccak256("Adapter8004"), keccak256("1"), chainId, proxy))

structHash = keccak256(abi.encode(
  keccak256("SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)"),
  account, agentId, nonce, deadline))

digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash))
```

The Foundry suite `test/security/Adapter8004.primaryAgent-with-sig.t.sol` builds these digests from
the literal type strings and verifies them on-chain, so any drift between the contract's private type
hashes and these strings fails there.

## Relayer / indexer notes

- Relayer: reconstruct the payload, re-read `nonces` immediately before broadcast, simulate, enforce
  deployment/chain allowlists and rate limits, and **never** extend a deadline.
- Indexer: update the reverse pointer once from the legacy `PrimaryAgentSet` / `PrimaryAgentCleared`
  event (`setBy`/`clearedBy` = relayer). Treat `PrimaryAgentSetWithSig` / `PrimaryAgentClearedWithSig`
  as provenance only (authorization = EIP-712, relayer, consumed nonce) — not a second state change.
  The combined call also emits `CounterfactualAgentRegistered` (and optional `CounterfactualAgentWalletSet`)
  with `emitter = signer` before the primary events.
- The reverse claim is self-asserted; a verified wallet↔agent link still requires the existing two-way
  check against the agent's own wallet claim.
