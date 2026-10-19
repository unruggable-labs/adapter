# v0.0.17 implementation deployment, Base and Ethereum

Date 2026-10-19. Deployed by Prem from the deployer `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` with `output/deploy-impl-create2.sh`. The implementations are deployed only. **No proxy was upgraded.** The Base and Ethereum proxies still point to their previous implementations until the Safe upgrade.

Method. The CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt zero and init code `AdapterImplementation` creation code plus `abi.encode(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)`, the same as Robinhood. So the implementation has the same address on all three chains. The init-code hash is `0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558`, built from `src/` unchanged since the audited `5f5c7fa`.

| | Base (8453) | Ethereum (1) |
|---|---|---|
| Implementation | `0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231` | `0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231` |
| Transaction | `0x0bca73a96a5b36d6c4d669edf815bd74971a0d10b067088177a4f0e01f17a8ba` | `0xa43c59004c714e2570846f2f793d741c97b21507dbfac9f0d5e080e649ebec88` |
| Block | 52824233 | 26228713 |
| Runtime keccak | `0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90` | same |
| `identityRegistry()` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | same |
| `proxiableUUID()` | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` | same |
| Etherscan family | verified, basescan.org | verified, etherscan.io |
| Sourcify | exact match, creation and runtime | exact match, creation and runtime |
| Proxy (unchanged) | `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27` | `0xde152AfB7db5373F34876E1499fbD893A82dD336` |
| Proxy still points to | `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` | `0xa6D23f27D3b1780B12488482a008cB3c3787135f` |

The runtime hash equals the Robinhood implementation at the same address. On Base, the script's receipt read failed after the transaction was sent, because a public RPC refused an archive request. The deployment was confirmed afterwards from the deployer nonce, the code at the address and Sourcify's deployment record. The script was then changed to send asynchronously and read the receipt from a second RPC.

Next. Per the final audit (`/Users/nxt3d/projects/idchain-audit/adapter-v0.0.17/CONSOLIDATED-FINDINGS.md`), before the Safe signs the Base upgrade, publish the F1 holder notice and the F2 wallet policy, correct the CHANGELOG, update the indexer, then produce the payload with `PrepareChainUpgrade.s.sol` against `NEW_IMPL=0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231` after a fresh pinned re-read. Ethereum follows after the Base soak period.
