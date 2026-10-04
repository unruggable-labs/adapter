# Adapter8004 delegate.xyz Upgrade Runbook - 2026-05-16

> **Historical runbook.** Its threshold, implementation, and signing steps
> describe the 2026-05-16 delegate.xyz rollout. Sepolia subsequently
> [upgraded to v0.0.17](v0.0.17-sepolia-preflight.md); Robinhood
> [deployed v0.0.17 directly](2026-09-29-robinhood-v0.0.17-deployment-report.md).
> Base's later [local fork acceptance](2026-09-29-base-v0.0.17-preparation.md)
> did not execute a production upgrade. Use fresh chain reads and the
> [v0.0.17 plan](v0.0.17-rollout-plan.md) for any remaining rollout.

## Summary

This runbook covers the UUPS upgrade that rolls out delegate.xyz v2 ERC-721
delegate support (commit `fd2fe40` on `main`) to the three production
`Adapter8004` proxies. Since the 2026-05-15 ownership transfer
([`2026-05-15-ownership-transfer-to-safe-report.md`](./2026-05-15-ownership-transfer-to-safe-report.md)),
every proxy is owned by the Gnosis Safe v1.4.1 (threshold 2) at
`0x03302Df40186D9B85faEA4fbb6cC5da028B23149`. The deployer EOA can no longer
call `upgradeToAndCall` directly — the upgrade itself MUST be executed by the
Safe.

The upgrade therefore has two steps per chain:

1. **EOA step** — the deployer EOA deploys the new implementation contract
   only. It does not, and cannot, call `upgradeToAndCall`.
2. **Safe step** — the Safe signers submit `upgradeToAndCall(newImplementation, 0x)`
   against the proxy through the Safe Transaction Builder.

This is a logic-only change. The new implementation adds only `constant`s
(`DELEGATE_REGISTRY`, `DELEGATE_RIGHTS`) and view logic; storage layout is
unchanged.

Owner / Safe (unchanged across all networks):

- `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (Gnosis Safe v1.4.1, threshold 2)

Implementation source: commit [`fd2fe40`](https://github.com/nxt3d/adapter/commit/fd2fe40) on `main`.

## Initializer bytes: none required

The `upgradeToAndCall` `data` argument (the post-upgrade initializer call)
is **empty (`0x`)**. Confirmed from code:

- `Adapter8004` has exactly one initializer, `initialize(address,address)`,
  guarded by the `initializer` modifier — it runs once at proxy creation.
- There is no `reinitializer(n)` function in the contract.
- The delegate.xyz change (`fd2fe40`) added only `constant` declarations
  (`DELEGATE_REGISTRY`, `DELEGATE_RIGHTS`), an internal `view` helper
  (`_isERC721Delegate`), and a refactor of the `view` `_hasBindingControl`
  overloads. Constants are compiled into bytecode and consume no storage
  slots, so there is no new state to initialize.
- `forge inspect Adapter8004 storage-layout` is byte-identical to the
  2026-05-15 baseline (SHA-256 `61f0912c13f31c8d66370291b3abb2ac9223f70d38074df39f6dc88114382f72`):
  `identityRegistry` at slot 0, `_bindings` at slot 1. `ReentrancyGuard`
  uses ERC-7201 namespaced storage outside the regular layout.

Therefore the Safe transaction calls `upgradeToAndCall(newImplementation, "")`.

## Pre-checks (all chains, before relying on delegate auth)

The delegate.xyz v2 registry is the immutable canonical contract at
`0x00000000000000447e69651d841bD8D104Bed493`. The adapter fails closed to
direct ownership when that address has no code, so before relying on
delegated authorization on any chain, confirm the registry is present:

```bash
cast code 0x00000000000000447e69651d841bD8D104Bed493 --rpc-url <chain-rpc>
```

Verified 2026-05-16 — the registry has code on all three target chains:

| Chain | `DELEGATE_REGISTRY` code present |
| --- | --- |
| Sepolia | yes (~10 KiB runtime) |
| Base | yes (~10 KiB runtime) |
| Ethereum Mainnet | yes (~10 KiB runtime) |

Current (pre-upgrade) implementation per proxy, from the EIP-1967 slot
`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`:

| Chain | Proxy | Current implementation |
| --- | --- | --- |
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0xFa8b53E82F6F1e17aDdFB5Db56f9eA26B24f4c4D` |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` |
| Ethereum Mainnet | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` |

These current implementations are also the **rollback targets** — see the
Rollback section.

## Rollout order

Roll out **Sepolia → Base → Ethereum Mainnet**. Do not advance to the next
chain until the prior chain's post-execution verification passes. Stop and
escalate on any failure; do not attempt recovery with the old deployer key.

## Step 1 — EOA deploys the new implementation (per chain)

The deployer EOA runs the new script, which deploys the implementation and
prints the Safe transaction parameters. It does **not** broadcast an
`upgradeToAndCall`.

```bash
ADAPTER_PROXY_ADDRESS=<chain proxy> \
  forge script script/DeployAdapterImplementation.s.sol:DeployAdapterImplementationScript \
  --rpc-url <chain-rpc> --broadcast
```

`DEPLOYER_PRIVATE_KEY` is read from `.env`. The script output includes:

- `new implementation (just deployed)` — record this address.
- `data (upgradeToAndCall(newImplementation, 0x))` — the exact calldata for
  the Safe transaction.

Record the new implementation address and the deployment tx hash from
`broadcast/DeployAdapterImplementation.s.sol/<chain-id>/run-latest.json`.

Optionally verify the implementation on the explorer:

```bash
forge verify-contract <new-impl> src/Adapter8004.sol:Adapter8004 \
  --chain-id <chain-id> --etherscan-api-key $ETHERSCAN_API_KEY --watch
```

## Step 2 — Safe executes the upgrade (per chain)

In the Safe Transaction Builder (https://app.safe.global) for the Safe
`0x03302Df40186D9B85faEA4fbb6cC5da028B23149` on the target chain, create a
new transaction with:

| Field | Value |
| --- | --- |
| `to` | the proxy address for that chain (see table below) |
| `value` | `0` |
| `data` | `upgradeToAndCall(newImplementation, 0x)` — the exact bytes printed by Step 1 |

The `data` is the ABI encoding of `upgradeToAndCall(address,bytes)`:

- selector `0x4f1ef286`
- 32 bytes — `newImplementation`, left-padded
- 32 bytes — offset to the bytes argument (`0x40`)
- 32 bytes — bytes length (`0x00`, i.e. empty initializer)

Total calldata length is 100 bytes. Use the Transaction Builder's
"raw transaction" / custom-data mode and paste the `data` bytes from Step 1;
do not hand-build it. Confirm `to` and `value = 0` before signing.

Collect the second signature (threshold 2) and execute.

### Per-chain Safe transaction parameters

`to` and `value` are known now. `data` is finalized only after Step 1 on
that chain, because the new implementation address depends on the deployer
EOA's nonce at deploy time. The `data` template is
`0x4f1ef286` + `pad32(newImplementation)` + `0x0000…0040` + `0x0000…0000`.

| Chain | Chain ID | `to` (proxy) | `value` | `data` |
| --- | --- | --- | --- | --- |
| Sepolia | `11155111` | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0` | `upgradeToAndCall(<step-1 impl>, 0x)` |
| Base | `8453` | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0` | `upgradeToAndCall(<step-1 impl>, 0x)` |
| Ethereum Mainnet | `1` | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0` | `upgradeToAndCall(<step-1 impl>, 0x)` |

Safe app links:

- Sepolia: https://app.safe.global/transactions/queue?safe=sep:0x03302Df40186D9B85faEA4fbb6cC5da028B23149
- Base: https://app.safe.global/transactions/queue?safe=base:0x03302Df40186D9B85faEA4fbb6cC5da028B23149
- Ethereum Mainnet: https://app.safe.global/transactions/queue?safe=eth:0x03302Df40186D9B85faEA4fbb6cC5da028B23149

## Step 3 — Post-execution verification (per chain, mandatory)

After the Safe transaction executes, confirm the implementation slot
changed before advancing to the next chain:

```bash
# Both must return the Step-1 new implementation address.
cast implementation <proxy> --rpc-url <chain-rpc>
cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url <chain-rpc>
```

Smoke-read a function that exists in the new implementation:

```bash
# Deterministic bytes32, chain-scoped; must not revert.
cast call <proxy> "registrationHash(address,uint256)(bytes32)" 0x000000000000000000000000000000000000dEaD 0 --rpc-url <chain-rpc>

# New delegate.xyz constants are readable behind the proxy.
cast call <proxy> "DELEGATE_REGISTRY()(address)" --rpc-url <chain-rpc>   # expect 0x00000000000000447e69651d841bD8D104Bed493
cast call <proxy> "DELEGATE_RIGHTS()(bytes32)" --rpc-url <chain-rpc>     # expect keccak256("adapter8004.manage")
```

If any check fails, STOP. Do not advance to the next chain and do not
attempt to upgrade or recover with the deployer EOA.

## Rollback

If a regression is found, the Safe can `upgradeToAndCall` back to the prior
implementation. Storage layout is unchanged, so rollback is safe and needs
no initializer bytes (`data = 0x`).

| Chain | Rollback implementation (pre-2026-05-16) |
| --- | --- |
| Sepolia | `0xFa8b53E82F6F1e17aDdFB5Db56f9eA26B24f4c4D` |
| Base | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` |
| Ethereum Mainnet | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` |

## Notes

- `script/UpgradeAdapter.s.sol` is the pre-Safe upgrade script: it calls
  `upgradeToAndCall` directly with `DEPLOYER_PRIVATE_KEY`. It is retained
  only for historical reference and broadcast artifacts. It is now
  non-functional against production — the deployer EOA is no longer the
  owner, so the call reverts `OwnableUnauthorizedAccount`. Use
  `script/DeployAdapterImplementation.s.sol` for all Safe-owned upgrades.
- This runbook produces the upgrade plan only. No on-chain upgrade has been
  broadcast or executed by this task.
