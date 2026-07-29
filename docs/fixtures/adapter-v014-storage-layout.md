# Adapter8004 v0.0.14 storage-layout evidence

Captured with `forge inspect Adapter8004 storageLayout`:

| Slot | Source name | Type | Policy |
|---:|---|---|---|
| 0 | `identityRegistry` | `IERC8004IdentityRegistry` | unchanged |
| 1 | `_bindings` | `mapping(uint256 => Binding)` | unchanged |
| 2 | `_primaryAgent` | `mapping(address => uint256)` | appended full pointer |
| 3 | `_primaryCounterfactualAgent` | `mapping(address => bytes32)` | appended CF pointer |
| 4 | `_primaryAgentNonces` | `mapping(address => uint256)` | appended full nonce |

The actual deployed Mainnet/Base (`a20035c`) and Sepolia (`4647ddd`) baselines contain only slots
0 and 1. No initializer or heuristic migration is used: direct upgrades use empty
`upgradeToAndCall` data. The upgrade tests start from minimal implementations with that exact
regular layout, populate slots 0 and 1, prove slots 2-4 are empty before the upgrade, preserve the
registry and binding, and verify new writes land at slots 2 and 3. Direct slot probes also verify
the full-system public nonce getter reads slot 4. A
separate Sepolia-baseline test proves delegate.xyz authorization survives the upgrade.
