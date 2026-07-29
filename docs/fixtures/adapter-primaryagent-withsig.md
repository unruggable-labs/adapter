# Adapter8004 v0.0.14 — full ERC-8004 primary signatures

The full system stores only registry `uint256 agentId` values. Read `primaryAgentNonces(account)`
immediately before signing. Signed authorization is account-self (EOA or ERC-1271); any relayer may
submit it. The deadline is inclusive and at most 30 minutes ahead.

## Domain and exact types

```text
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)
ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)
```

Domain values are `name = "Adapter8004"`, `version = "1"`, the numeric EVM `chainId`, and the
adapter proxy as `verifyingContract`.

```ts
const nonce = await publicClient.readContract({
  address: adapter, abi, functionName: 'primaryAgentNonces', args: [account],
})
const types = {
  SetPrimary8004Agent: [
    { name: 'account', type: 'address' },
    { name: 'agentId', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const
const signature = await walletClient.signTypedData({
  account, domain, types, primaryType: 'SetPrimary8004Agent',
  message: { account, agentId, nonce, deadline },
})
const data = encodeFunctionData({
  abi, functionName: 'setPrimaryAgentWithSig',
  args: [account, agentId, deadline, signature],
})
```

ABI fragment:

```json
[
  {"type":"function","name":"primaryAgentNonces","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
  {"type":"function","name":"setPrimaryAgentWithSig","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"},{"name":"agentId","type":"uint256"},{"name":"deadline","type":"uint256"},{"name":"signature","type":"bytes"}],"outputs":[]},
  {"type":"function","name":"clearPrimaryAgentWithSig","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"},{"name":"deadline","type":"uint256"},{"name":"signature","type":"bytes"}],"outputs":[]},
  {"type":"event","name":"PrimaryAgentSetWithSig","anonymous":false,"inputs":[{"name":"account","type":"address","indexed":true},{"name":"agentId","type":"uint256","indexed":true},{"name":"relayer","type":"address","indexed":true},{"name":"nonce","type":"uint256","indexed":false}]}
]
```

Digest:

```text
structHash = keccak256(abi.encode(
  keccak256("SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)"),
  account, agentId, nonce, deadline))
digest = keccak256(hex"1901" || domainSeparator || structHash)
```

The state event is emitted before the supplemental `WithSig` event. `type(uint256).max` is reserved
as unset; agent ID zero is valid.
