# Robinhood acceptance and Base v0.0.17 preparation

Task: `robinhood-live-base-preparation`. Based on `dbf8620` on `v0.0.17`, pulled before edits. No contract source/compiler/dependency changes. No broadcasts, keys read, Safe proposals, or pushes.

## Acceptance evidence

- Robinhood live proxy `0x000000009d62675362a58911e3f32FEcf46F5E18`, block **75787273**, hash `0x9dc1bb4584b9df6da061368ef85e14dfe84344123211a7391ac239fa60094d57`: all eight standards register through the actual registry; controller denials and real delegate registry checks; URI/metadata/wallet operations (including real ERC-1271 signature validation); locally deployed future implementation installed by the actual Safe using two approved hashes. One approval and a non-UUPS target fail. Bindings, metadata, URI, nonzero wallet, slot 0, owner and registry survive. Safe threshold stays 2; nonce increments once.
- Pre-deploy rehearsal defaults to **75784375**, with Prem's exact eight-nibble salt. Requires block <= 75784375 and reconstructs the deployed implementation/proxy addresses through the actual factory. Both rehearsal and live modes pass. Live mode rejects blocks before proxy deployment. Earlier pin 75781185 encountered an RPC historical-state error; 75784375 passed.
- Base live proxy `0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27`, block **51954357**, hash `0xc37e366d6aa0e4ca5548ceda2600c1e25fde56e7d8f3735a8688db2ac795718d`: baseline `0x0f81bd4EDD4879734361A1A44460264CBf6F94c9` / runtime `0xe41935cf07fd522c59c7d317ebef5d540e22d38fe76ad5a59d44458036fe2200`, corresponding to `a20035c`. Safe nonce 1, threshold 3-of-4. Local candidate upgraded via the actual Safe and three sorted approved-hash signatures; two signatures and a non-UUPS target fail. No Safe impersonation bypass is used for upgrades.
- Six historical bindings are authenticated against raw `AgentBound` logs in `base-agentbound-sample.json`: **54940, 54941, 54943, 54977, 61381, 61384**. The test asserts their logged standard/address/token coordinates, registry owner/URI/wallet/metadata, and both raw binding storage words before/after. Slot 0 retains the legacy registry word even though the new getter uses an immutable. These are sampled records, not an exhaustive binding audit.
- Base newly registered legacy binding retains state after upgrade; delegate authorization changes from false to true through the actual delegate registry. Removed calls `registrationHash`, `setIdentityRegistry`, `rewriteBindingMetadata`, and two-argument `initialize` reject after upgrade. Delegate getters are absent before upgrade. `counterfactualPayloadVersion` is absent in both releases.
- On-chain `setMetadataBatch` keeps its call selector but replaces one `MetadataBatchSet` count event with a `MetadataSet` event per entry; the test asserts both historical and new log shapes and registry writes.
- Counterfactual registration's topic is unchanged but its indexed hash changes. All five setters change event topics and change from empty return data to a returned UBID. Assertions exercise both sides through the actual outgoing implementation and local candidate.
- `PrepareChainUpgrade.s.sol` supports explicit Base/Ethereum mappings and rejects other chains, missing code, changed baseline/owner/registry, incompatible UUPS, non-3-of-4 Safe, and runtime mismatches. It compares the actual runtime with a local build after patching only the three UUPS `__self` words; the registry immutable is constructor-populated. Runtime hashes are address-dependent: do not copy Robinhood's hash for an ordinary CREATE deployment on Base. It then rehearses the exact calldata through the real Safe, locally. The Base fork asserts the resulting JSON target, chain, value, and calldata. Ethereum's mapping is prepared; Ethereum fork acceptance is still its separate #3 rollout gate.
- Full offline suite: **490 passed, 0 failed, 4 opt-in forks skipped**. Explicit Base fork plus generator guards: **5 passed**. Explicit Robinhood modes: **2 passed**. Logs: `postdeploy-full-suite.log`, `base-fork-acceptance-final.log`, `robinhood-postdeploy-final.log`.

## Repeat the forks (no keys)

From the release worktree:

```bash
cd /Users/nxt3d/projects/adapter-0.0.17
ROBINHOOD_FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
ROBINHOOD_LIVE_BLOCK=75787273 \
forge test --match-contract Adapter8004RobinhoodForkTest -vv

BASE_FORK_RPC_URL=https://mainnet.base.org BASE_FORK_BLOCK=51954357 \
forge test --match-contract 'Adapter8004BaseForkTest|PrepareChainUpgradeTest' -vv
```

For a fresh snapshot, replace the live block variables with `cast block-number` results and save the block hash. Keep the Robinhood rehearsal pin at 75784375. Base PublicNode rejected some historical storage requests without an archive token; the official Base RPC passed. Archive availability remains necessary for old pins.

## Prem: deploy the Base implementation

Run these in **bash**, using the adapter `.env` deployer key. No Ledger and no proxy upgrade in this step. The two deployment methods below are alternatives: run **one**. The guard checks the full signer address and Base chain ID before either send. An implementation deployment leaves the proxy on its current baseline.

```bash
set -euo pipefail
set +x
cd /Users/nxt3d/projects/adapter-0.0.17
source /Users/nxt3d/projects/adapter/.env
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY missing from adapter .env}"
export BASE_RPC_URL=https://mainnet.base.org
export REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
check_base_signer() {
  test "$(cast chain-id --rpc-url "$BASE_RPC_URL")" = 8453
  test "$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY" | tr '[:upper:]' '[:lower:]')" \
    = 0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef
}
check_base_signer
forge build

# Preferred: deploy only AdapterImplementation with its registry constructor argument.
check_base_signer
forge create src/AdapterImplementation.sol:AdapterImplementation \
  --rpc-url "$BASE_RPC_URL" --chain 8453 \
  --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast \
  --constructor-args "$REGISTRY"
```

Equivalent **alternative** using `cast send` (do not run after successful `forge create`):

```bash
# Same setup and guard function as above.
check_base_signer
creation_code=$(forge inspect src/AdapterImplementation.sol:AdapterImplementation bytecode)
constructor_args=$(cast abi-encode 'constructor(address)' "$REGISTRY")
implementation_init_code="${creation_code}${constructor_args#0x}"
cast send --rpc-url "$BASE_RPC_URL" --chain 8453 \
  --private-key "$DEPLOYER_PRIVATE_KEY" --create "$implementation_init_code"
```

Record the successful receipt and actual `contractAddress` (never a prediction). Verify source, constructor argument, compiler 0.8.30, Prague, optimizer 200, and exact runtime against this release. Sourcify verification command:

```bash
export ADAPTER_IMPLEMENTATION_ADDRESS=0xACTUAL_RECEIPT_CONTRACT_ADDRESS
forge verify-contract "$ADAPTER_IMPLEMENTATION_ADDRESS" \
  src/AdapterImplementation.sol:AdapterImplementation \
  --chain 8453 --verifier sourcify --watch \
  --constructor-args "$(cast abi-encode 'constructor(address)' "$REGISTRY")"
```

Replace the explicit placeholder before running. Preserve the exact-match result and receipt. No concrete Safe JSON is emitted in this preparation task because the real Base implementation address does not yet exist.

## After deployment: actual-address acceptance and Safe JSON

These commands are keyless and local simulations. Run only after the implementation is source-verified. The generator rebuilds the address-dependent expected runtime itself; the captured runtime hash pins the reviewed live bytes too.

```bash
export BASE_FORK_RPC_URL="$BASE_RPC_URL"
export BASE_FORK_BLOCK=$(cast block-number --rpc-url "$BASE_RPC_URL")
export BASE_IMPLEMENTATION_ADDRESS="$ADAPTER_IMPLEMENTATION_ADDRESS"
cast block "$BASE_FORK_BLOCK" --rpc-url "$BASE_RPC_URL" --json \
  > output/base-pre-sign-block.json
export EXPECTED_IMPLEMENTATION_CODEHASH=$(cast code "$ADAPTER_IMPLEMENTATION_ADDRESS" \
  --block "$BASE_FORK_BLOCK" --rpc-url "$BASE_RPC_URL" | cast keccak)
forge test --match-contract Adapter8004BaseForkTest -vv
forge script script/PrepareChainUpgrade.s.sol:PrepareChainUpgradeScript \
  --rpc-url "$BASE_RPC_URL" --fork-block-number "$BASE_FORK_BLOCK" -vv
```

Output: `deployments/v0.0.17-safe-tx-8453-verified.json`, one value-zero CALL to the **proxy**, `upgradeToAndCall(actualImplementation, 0x)`. No initializer. No `--broadcast`, `--resume`, private-key option, or Safe service API on the generator. JSON preparation does not submit a proposal. Actual Safe nonce/configuration must be rechecked before signing; the JSON description records the rehearsed nonce/block, but Transaction Builder chooses the eventual Safe nonce. Ethereum uses the same script on chain 1 and outputs `...-1-verified.json` only after its separate acceptance/deployment gates.

## Base indexer cutover checklist

1. Save the current ABI and source baseline `a20035c`. Keep pre-upgrade history keyed by `keccak256(abi.encode(uint256(8453), proxy, tokenContract, tokenId))`. Do not reconstruct old hashes with the new helper or merge old claims into UBID records automatically.
2. Gate the cutover on the successful Safe receipt and proxy `Upgraded(actualImplementation)` plus the final implementation slot. Record block hash/number, transaction index/hash, and log index. Split decoding by execution order within the upgrade block, not only block number. Handle reorgs by reverting to the last canonical checkpoint; wait for the operator's chosen Base finality policy before treating the cutover as final.
3. `CounterfactualAgentRegistered(bytes32,address,uint256,uint8,string,(string,bytes)[],address)` has the **same topic** on both sides. After the cutover, its key is `keccak256(abi.encode(interoperableAddress(proxy), standard, boundAddress, tokenId))`. Standard is part of identity now; keep enum values 0–2 and accept appended 3–7. There is **no version byte or payload-version getter** in this release.
4. Switch all five counterfactual setter decoders at the boundary: v0.0.17 inserts `uint8 standard` after `tokenId` in URI, metadata, metadata-batch, wallet-set and wallet-unset event data/signatures. Their topics change. New calls return UBID; legacy setter calls returned no data. Existing `AgentBound` signature and agent IDs remain stable. On-chain metadata batches stop emitting `MetadataBatchSet` and emit one `MetadataSet` per entry; adjust projections accordingly.
5. Add WalletUBID and attestation event handling from the v0.0.17 ABI. Preserve event order; wallet reverse claims are self-assertions and require the matching forward claim for a trusted relationship. Do not migrate unreleased primary-agent or bindExisting state; those surfaces were never active on this baseline.
6. Replay a window on both sides and compare sampled bindings/URI/metadata/wallets and old/new hash fixtures. Check removals (`registrationHash`, registry setter, binding-metadata rewrite, old initializer), new controller/delegate behavior and new standards in application callers. Capture post-upgrade slot/owner/registry/threshold/nonce and real registry smoke results before closing the rollout.

Remaining gates: Prem's implementation deployment and exact source verification, fresh actual-address acceptance/generator run, indexer cutover readiness and finality policy, then separately authorized Safe signing/execution. No code blocker found in the tested Base path. No Base or Ethereum proxy was changed on-chain.
