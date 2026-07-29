# Adapter8004 upgrade baseline: use the active deployed implementation

Last verified: 2026-07-29

## Rule

For a UUPS upgrade, the baseline is the implementation currently selected by
the proxy's EIP-1967 implementation slot. It is not:

- the highest `@custom:version` in source;
- the last numbered changelog entry;
- the newest implementation contract deployed on that chain; or
- an implementation address embedded in a prepared Safe Transaction Builder
  JSON.

A deployed implementation is inert until the Safe successfully executes
`upgradeToAndCall` against the proxy. A prepared or signed Safe payload is not
execution evidence.

## Active implementation by chain

The following values were re-read directly from EIP-1967 slot
`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
on 2026-07-29. `owner()` on all three proxies is the Safe
`0x03302Df40186D9B85faEA4fbb6cC5da028B23149`.

| Chain | Proxy | Active implementation | Exact deployed source baseline | Proxy upgraded after 2026-05-15? |
| --- | --- | --- | --- | --- |
| Ethereum mainnet | `0xde152AfB7db5373F34876E1499fbD893A82dD336` | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` | counterfactual/event/reentrancy build, commit `a20035c` | No |
| Base | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` | counterfactual/event/reentrancy build, commit `a20035c` | No |
| Sepolia | `0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92` | `0x31a68E5bc0224ad081d6Ec20229B05F558609257` | delegate.xyz build deployed from commit `4647ddd` (delegate logic introduced by `fd2fe40`) | **Yes** |

The 2026-05-15 report records successful upgrades of all three proxies to
their chain-specific `a20035c` implementations. The 2026-05-16 report then
records implementation-only deployments of the delegate.xyz build on Sepolia
and Base and explicitly says that no proxy was touched during that task.
The prepared Safe payloads target those two implementations. Subsequent
execution is evidenced only for Sepolia: its live slot is now
`0x31a68E5b...`, and `DELEGATE_REGISTRY()` succeeds through the proxy. Base's
slot is still `0x0f81bd4E...`, and both `DELEGATE_REGISTRY()` and
`counterfactualPayloadVersion()` revert there. Mainnet behaves like Base.

### Later implementations and payloads that are not live

| Chain | Candidate/payload | What actually happened | Upgrade baseline? |
| --- | --- | --- | --- |
| Sepolia | delegate.xyz `0x31a68E5b...` | Implementation deployed; Safe upgrade later executed | **Yes: active** |
| Base | delegate.xyz `0x0e30C112...` | Implementation deployed and verified; prepared Safe payload was not executed | No |
| Mainnet | delegate.xyz | Deployment attempt failed before broadcast; no implementation and no finalized payload | No |
| Sepolia | `0.0.6` bindExisting/versioned-counterfactual payload | Template with placeholder implementation data | No |
| Base | `0.0.6` bindExisting/versioned-counterfactual payload | Template with placeholder implementation data | No |
| Mainnet | purported `0.0.6` implementation `0xB36Cb6D7...` | **Not deployed.** The matching Foundry artifact is dry-run-only (no transaction hash or receipts), and the address has no runtime code. The Safe payload was not executed. | No; payload is unsafe |

The Mainnet `0.0.6` JSON originally described `0xB36Cb6D7...` as deployed.
That is contradicted by `broadcast/DeployAdapterImplementation.s.sol/1/` and
the chain itself. Calling `upgradeToAndCall` with a no-code target would fail
the UUPS implementation validation; do not import or sign that payload.

## Storage baseline

Both active source baselines (`a20035c` and `4647ddd`) have the same regular
storage layout:

| Slot | Field | Type |
| ---: | --- | --- |
| 0 | `identityRegistry` | `IERC8004IdentityRegistry` |
| 1 | `_bindings` | `mapping(uint256 => Binding)` |

OZ v5 `Initializable`, `OwnableUpgradeable`, UUPS, and `ReentrancyGuard` use
namespaced storage. In particular, the May 15 upgrade added the
`ReentrancyGuard` namespace without adding a regular slot.

The current unreleased `0.0.14` source intentionally lays out:

| Slot | `0.0.14` field | Live-state implication |
| ---: | --- | --- |
| 0 | `identityRegistry` | Must remain byte-for-byte compatible |
| 1 | `_bindings` | Must remain byte-for-byte compatible |
| 2 | `_primaryAgent` | Newly appended, initially empty |
| 3 | `_primaryCounterfactualAgent` | Newly appended, initially empty |
| 4 | `_primaryAgentNonces` | Newly appended, initially zero |

The live `Binding` remains `(TokenStandard standard, address tokenContract,
uint256 tokenId)`. `0.0.14` appends `ERC1155F` and `ERC6909F` after the live
enum values `ERC721`, `ERC1155`, and `ERC6909`, so stored values `0`, `1`, and
`2` keep their meanings.

There is no storage initializer or migration required for a direct upgrade
from the active implementations to the reviewed `0.0.14` layout. The empty
slot values make both new primary getters return their explicit unset
sentinels. This conclusion depends on upgrading directly from the active
implementations above, not from an imagined numbered release.

### Storage footguns

1. **Do not validate only `0.0.13 -> 0.0.14`.** `0.0.9` first introduced
   slot 2, `0.0.10` changed its encoding, and `0.0.11` introduced slot 3.
   None was deployed. Treating those source versions as the production
   baseline invents primary-agent state and migration obligations that do not
   exist on these proxies.
2. **Do not reserve storage for unreleased source layouts.** No live proxy
   received the `0.0.9`-`0.0.13` primary-agent fields, so `0.0.14` appends its
   three mappings directly at slots 2-4. Treating unreleased declarations as
   production history would create unnecessary permanent gaps.
3. **Do not roll an intermediate `0.0.9`-`0.0.13` build onto one chain.**
   That would create chain-specific state in slots 2/3 and turn the currently
   simple direct-upgrade analysis into a real migration and indexer problem.
4. **Compare against both live ABIs.** Sepolia's active implementation has
   delegate.xyz authorization and the `DELEGATE_REGISTRY` /
   `DELEGATE_RIGHTS` getters. A future implementation built only from the
   Mainnet/Base baseline can accidentally remove behavior already live on
   Sepolia even if its storage layout is safe.

## ABI and semantic compatibility

The active Mainnet/Base ABI is the `a20035c` counterfactual ABI. Sepolia adds
the two delegate.xyz constant getters and delegate authorization logic. None
of the live proxies currently exposes `bindExisting`,
`counterfactualPayloadVersion`, either primary-agent system, or the newer
ERC-1155F/ERC-6909F behavior.

The current `0.0.14` source is broadly selector-additive relative to the live
ABI, but two counterfactual changes are hard cutovers:

- **Event topics change.** Live counterfactual events have no leading
  `uint8 version`. The unreleased versioned family adds it, changing every
  counterfactual event signature/topic. Indexers must retain the old topics
  through the upgrade block and begin the new topics at the exact cutover
  block.
- **`registrationHash(address,uint256)` keeps its selector but changes its
  result.** Live code computes
  `keccak256(abi.encode(block.chainid, address(proxy), tokenContract,
  tokenId))`. `0.0.14` computes
  `keccak256(abi.encode(interoperableAddress(proxy), tokenContract,
  tokenId))`. ABI compatibility therefore hides a semantic break. Old event
  keys do not become the new keys, and the post-upgrade helper cannot be used
  to reconstruct pre-upgrade hashes.

Additional planning implications:

- `bindExisting`, `cf-registration` reservation, payload version 1,
  counterfactual signatures, and primary-agent APIs are unreleased source
  behavior, not live behavior.
- Primary-agent state/events from `0.0.9`-`0.0.13` do not need production
  migration because those versions were never active. The pre-rollout
  "zero legacy primary events" gate should nevertheless be retained as an
  operational assertion against an unexpected chain divergence.
- EIP-712 signatures prepared against unreleased intermediate type hashes,
  nonce locations, or old counterfactual hashes must not be accepted as
  production migration inputs. Users sign only after the final deployed
  domain/types are published.
- A single future implementation may target all chains, but its test matrix
  must use `a20035c` state/ABI for Mainnet and Base and `4647ddd` state/ABI
  for Sepolia. The common storage layout does not erase the behavioral
  difference.

## Required pre-upgrade evidence for any future rollout

Before preparing a new Safe transaction for a chain:

1. Re-read the proxy's EIP-1967 implementation slot and `owner()`.
2. Match the implementation runtime bytecode/source to the appropriate
   baseline above.
3. Run storage-layout validation from that exact baseline to the proposed
   implementation, including OZ namespaced storage.
4. Diff functions, errors, and events against that chain's active ABI.
5. Define the counterfactual old-topic/new-topic and old-hash/new-hash
   cutover block for indexers.
6. Deploy and verify the new implementation, then generate calldata from
   that actual address. A dry-run-predicted address is not sufficient.
7. Treat the proxy slot change and executed Safe transaction as completion;
   implementation deployment alone is not an upgrade.

## Repository evidence

- [`2026-05-15-counterfactual-upgrade-report.md`](./2026-05-15-counterfactual-upgrade-report.md)
- [`2026-05-16-delegate-xyz-implementation-deployment-report.md`](./2026-05-16-delegate-xyz-implementation-deployment-report.md)
- [`2026-05-16-delegate-xyz-upgrade-runbook.md`](./2026-05-16-delegate-xyz-upgrade-runbook.md)
- [`2026-05-16-delegate-xyz-safe-tx-sepolia.json`](./2026-05-16-delegate-xyz-safe-tx-sepolia.json)
- [`2026-05-16-delegate-xyz-safe-tx-base.json`](./2026-05-16-delegate-xyz-safe-tx-base.json)
- [`2026-05-16-delegate-xyz-safe-tx-mainnet.json`](./2026-05-16-delegate-xyz-safe-tx-mainnet.json)
- [`2026-05-20-bindexisting-counterfactual-v1-safe-tx-mainnet.json`](./2026-05-20-bindexisting-counterfactual-v1-safe-tx-mainnet.json)
- [`../docs/fixtures/adapter-v014-storage-layout.md`](../docs/fixtures/adapter-v014-storage-layout.md)
