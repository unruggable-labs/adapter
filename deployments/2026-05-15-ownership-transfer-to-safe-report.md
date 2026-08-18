# Adapter8004 Ownership Transfer to Safe Multisig Report - 2026-05-15

> **Superseded:** `rewriteBindingMetadata` and `script/MigrateBindingMetadata.s.sol` were removed in
> `0.0.16`. The migration they describe was a prepared no-op for all three production proxies and was
> never required. See CHANGELOG.md. This report is kept as the dated record.


## Summary

`OwnableUpgradeable` ownership of every production `Adapter8004` proxy
was transferred from the deployer EOA
`0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` to Gnosis Safe v1.4.1 at
`0x03302Df40186D9B85faEA4fbb6cC5da028B23149`. The same Safe address is
deployed on Sepolia, Base, and Ethereum mainnet (threshold 2). The
transfer used the single-step `transferOwnership(address)` path on
`OwnableUpgradeable`; there is no two-step accept dance.

Each chain was pre-verified immediately before its transfer:

- `cast call <proxy> owner()` returned the expected deployer EOA.
- `cast code <safe>` returned non-empty bytecode on that chain.
- `cast call <safe> VERSION()` returned `"1.4.1"`.

Each chain was post-verified immediately after its transfer:

- `cast call <proxy> owner()` returned the Safe address.

## Sepolia

- Date (UTC): `2026-05-15 06:16:12`
- Chain ID: `11155111`
- Adapter proxy: `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92`
- Previous owner: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- New owner: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (Safe v1.4.1)
- `transferOwnership` tx: `0x838ef6948f97ec583444165ec3a0e850bddb385dddedc6fb8004ac31608612af`
- Block: `10855676`
- Gas spent: `33,563` gas (`0.000000033563637697 ETH` at `1,000,019` wei effective gas price)
- Etherscan: https://sepolia.etherscan.io/tx/0x838ef6948f97ec583444165ec3a0e850bddb385dddedc6fb8004ac31608612af
- Pre-transfer `owner()`: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- Post-transfer `owner()`: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149`
- Safe `VERSION()`: `1.4.1`
- Broadcast artifact: [`broadcast/TransferAdapterOwnership.s.sol/11155111/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/TransferAdapterOwnership.s.sol/11155111/run-latest.json)

## Base

- Date (UTC): `2026-05-15 06:16:53`
- Chain ID: `8453`
- Adapter proxy: `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`
- Previous owner: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- New owner: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (Safe v1.4.1)
- `transferOwnership` tx: `0x89fe7ab399574eee5eb5f3a5c8bce2463b45ec469b00b8b23b8a978c8d06adc3`
- Block: `46018233`
- Gas spent: `33,563` gas (`0.000000172513820000 ETH` at `5,140,000` wei effective gas price)
- Basescan: https://basescan.org/tx/0x89fe7ab399574eee5eb5f3a5c8bce2463b45ec469b00b8b23b8a978c8d06adc3
- Pre-transfer `owner()`: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- Post-transfer `owner()`: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149`
- Safe `VERSION()`: `1.4.1`
- Broadcast artifact: [`broadcast/TransferAdapterOwnership.s.sol/8453/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/TransferAdapterOwnership.s.sol/8453/run-latest.json)

## Ethereum Mainnet

- Date (UTC): `2026-05-15 06:17:35`
- Chain ID: `1`
- Adapter proxy: `0xde152AfB7db5373F34876E1499fbD893A82dD336`
- Previous owner: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- New owner: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (Safe v1.4.1)
- `transferOwnership` tx: `0xdd99681a51dcd3d2657560029049a83737d68bb914120499b594395ff60b7b80`
- Block: `25098696`
- Gas spent: `33,563` gas (`0.000004412786045100 ETH` at `131,477,700` wei effective gas price)
- Etherscan: https://etherscan.io/tx/0xdd99681a51dcd3d2657560029049a83737d68bb914120499b594395ff60b7b80
- Pre-transfer `owner()`: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`
- Post-transfer `owner()`: `0x03302Df40186D9B85faEA4fbb6cC5da028B23149`
- Safe `VERSION()`: `1.4.1`
- Broadcast artifact: [`broadcast/TransferAdapterOwnership.s.sol/1/run-latest.json`](/Users/nxt3d/projects/adapter/broadcast/TransferAdapterOwnership.s.sol/1/run-latest.json)

## Operational notes

- The deployer EOA `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` can no
  longer perform any `onlyOwner` action on any production proxy. In
  particular, `upgradeToAndCall`, `setIdentityRegistry`, and
  `rewriteBindingMetadata` all revert with
  `OwnableUnauthorizedAccount` against the deployer key.
- All future upgrades must be proposed through the Safe at
  `0x03302Df40186D9B85faEA4fbb6cC5da028B23149` (threshold 2). The
  Safe Transaction Builder UI is the recommended workflow: target the
  proxy address, call `upgradeToAndCall(newImplementation, data)` (or
  `setIdentityRegistry(newRegistry)` / `rewriteBindingMetadata(agentId)`
  as appropriate), collect the second signature, then execute.
- This transfer used `OwnableUpgradeable.transferOwnership(address)`,
  not `Ownable2StepUpgradeable`. There is no pending-owner acceptance
  step; ownership moved atomically when the transaction confirmed.
- `renounceOwnership()` is still callable by the new Safe owner.
  Calling it would permanently lock out upgrades and registry
  repointing on the affected chain.
