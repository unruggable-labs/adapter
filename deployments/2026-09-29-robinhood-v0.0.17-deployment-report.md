# Adapter v0.0.17 — Robinhood Chain Mainnet Deployment (2026-09-29)

**Chain:** Robinhood Chain mainnet (4663)
**Signer:** deployer EOA `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (two plain CALLs to the CREATE2 factory; no Safe transaction)
**Owner:** Safe `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (2-of-4 on Robinhood, by Prem's decision)
**Status:** ✅ implementation + vanity proxy deployed, owner set atomically, both sources verified on Sourcify (exact match)

## Addresses

| Contract | Address |
|----------|---------|
| **Adapter (ERC1967 / UUPS proxy)** | `0x000000009d62675362a58911e3f32FEcf46F5E18` |
| Implementation (`AdapterImplementation` v0.0.17) | `0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231` |
| ERC-8004 IdentityRegistry (immutable in the implementation) | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| delegate.xyz DelegateRegistry v2 (constant) | `0x00000000000000447e69651d841bD8D104Bed493` |
| CREATE2 factory | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

The proxy address has 8 leading zero nibbles. Prem chose it from the 30-minute mine over the
10-nibble best (`0x00000000003b7536…c5A2`); see `v0.0.17-rollout-plan.md` "Completed 30-minute mine".
Proxy salt `0x18d9d345878344f000000000000000040000000000000000000000000a632f3f`; implementation salt zero.

The registry and delegate registry addresses match the maintainers' published lists
(erc-8004/erc-8004-contracts README "Robinhood Chain Mainnet"; delegatexyz/delegate-registry README
"Finalized Deployment"). Their live runtimes on Robinhood are byte-identical to Base and Ethereum:
delegate registry `0x9dec…1ba9` (10,046 bytes); registry proxy `0xd0e4…2b41`, implementation
`0x7274e874…9c02` (`0xa5f9…c16f`), `AgentIdentity`/`AGENT` v2.0.0, owner `0x5472…2603`.

## Transactions

| # | Step | Hash | Block | UTC | Gas | Fee (wei) |
|---|------|------|-------|-----|-----|-----------|
| 1 | Implementation: factory CALL, salt 0, nonce 0 | `0x093d4e55be31cec797c8a0483c2b7e6e96a074cb6aacf1d749317fd7741c3b04` | 75784376 | 2026-09-29 16:02:50 | 3,629,473 | 75,899,539,376,000 |
| 2 | Proxy: factory CALL, mined salt, nonce 1, `initialize(Safe)` in the constructor | `0xb029f85fa738dab5a98423734fc7f7ff36337364eb5d942c8b658337f37ae3e3` | 75785682 | 2026-09-29 16:05:01 | 178,622 | 3,847,517,880,000 |

Both receipts `status 1`. Each transaction's input is byte-equal to the payload rebuilt by
`output/robinhood-signing-inputs.sh`. Transaction 1 emitted `Initialized(type(uint64).max)` on the
implementation (initializers disabled). Transaction 2 emitted, on the proxy, `Upgraded(0x3d74…5231)`,
`OwnershipTransferred(0x0, Safe)` and `Initialized(1)`.

Proxy deployment boundary for indexers: block 75785682, tx index 2, log indices 0–2. There is no
earlier Adapter history at this address; index with the v0.0.17 ABI from this block.

## Source and build

- Source: `v0.0.17` @ `1f72f0c` (contract source unchanged since); tooling `82c47bc`; salt selection `dc46825`.
- solc 0.8.30, evm `prague`, optimizer 200 runs, non-via-IR, default metadata; Foundry 1.3.5.
- Pins: forge-std `4540e4a`, OpenZeppelin `5fd1781`, OpenZeppelin upgradeable `7bf4727` (v5.6.1), erc-8004-contracts `c7ce292`.
- Implementation init-code hash `0x5b3785cf…1558`; proxy init-code hash `0xbb43a76d…9953`.

## Verification

Before signing: full suite 486 passed / 0 failed; the Robinhood fork rehearsal (real factory, registry,
delegate registry and Safe, all eight standards, a future upgrade through the Safe at threshold 2)
passed with the selected salt at block 75781185; the keyless `DeployVanityProxy` dry run predicted
both addresses; read-only preflight `initial` passed. CTO evidence is in the rollout plan and `output/`.

Between the transactions (`preflight --phase implementation` passed at block 75784486):
runtime 16,284 bytes, keccak `0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90`
(= the independently rebuilt hash with immutables patched); `identityRegistry()` = registry;
`proxiableUUID()` = the ERC-1967 slot; `owner()` = zero; `initialize` reverts `InvalidInitialization()`;
the proxy address was empty; simulating transaction 2 returned the vanity address.

After (`preflight --phase proxy` passed at block 75785792):
proxy runtime 163 bytes (`0xa9c0…b17a`); EIP-1967 slot = `0x3d74…5231`; `owner()` = Safe;
`identityRegistry()` = registry; slot 0 zero; `initialize` reverts `InvalidInitialization()`;
Safe still 2-of-4, nonce 0; deployer nonce 2.

Source verification: Sourcify exact match (creation + runtime) for both, implementation match
54030657, proxy match 54031560. The Blockscout API sits behind a Cloudflare challenge from this
environment; Blockscout reads Sourcify matches.

Note: `test/Adapter8004.robinhood-fork.t.sol` is a pre-deployment rehearsal and asserts both CREATE2
destinations are empty, so it now fails at blocks after 75784376 by design. Pin
`ROBINHOOD_FORK_BLOCK` at or below 75784375 (archive RPC) to reproduce it.

## Rollback / recovery

There is no previous implementation. Repairs go through the owner Safe (2-of-4) as a rehearsed UUPS
`upgradeToAndCall(newImpl, 0x)`. The proxy address and salt are spent.

## Machine-readable

```json
{
  "chainId": 4663,
  "network": "robinhood-mainnet",
  "deployedAt": "2026-09-29",
  "contract": "AdapterImplementation",
  "version": "0.0.17",
  "proxy": "0x000000009d62675362a58911e3f32FEcf46F5E18",
  "implementation": "0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231",
  "owner": "0x03302Df40186D9B85faEA4fbb6cC5da028B23149",
  "safeThreshold": 2,
  "identityRegistry": "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  "delegateRegistry": "0x00000000000000447e69651d841bD8D104Bed493",
  "create2Factory": "0x4e59b44847b379578588920cA78FbF26c0B4956C",
  "proxySalt": "0x18d9d345878344f000000000000000040000000000000000000000000a632f3f",
  "implementationSalt": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "implementationRuntimeKeccak": "0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90",
  "proxyRuntimeKeccak": "0xa9c092f12ac0cf28336ae9fc3aa7c6e11411d6dbbb033cedb4f41a93da2eb17a",
  "sourceCommit": "1f72f0c",
  "toolingCommit": "82c47bc",
  "deployer": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "transactions": {
    "deployImplementation": "0x093d4e55be31cec797c8a0483c2b7e6e96a074cb6aacf1d749317fd7741c3b04",
    "deployProxy": "0xb029f85fa738dab5a98423734fc7f7ff36337364eb5d942c8b658337f37ae3e3"
  },
  "blocks": { "deployImplementation": 75784376, "deployProxy": 75785682 },
  "sourcify": { "implementation": "exact_match", "proxy": "exact_match" }
}
```
