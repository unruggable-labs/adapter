#!/usr/bin/env bash
# Deploys the v0.0.17 AdapterImplementation through the CREATE2 factory with salt zero,
# the same way as Robinhood, so the implementation lands at the same address on every chain.
# Usage, from the repo root: bash output/deploy-impl-create2.sh base|mainnet
# Prem runs this. It reads DEPLOYER_PRIVATE_KEY from /Users/nxt3d/projects/adapter/.env (override with ENV_FILE) and never prints it.
# It does not touch any proxy. The proxy upgrade is a separate Safe transaction.
set -euo pipefail

case "${1:-}" in
  base)    CHAIN_ID=8453; RPC_URL=https://base-rpc.publicnode.com;     RECEIPT_RPC=https://mainnet.base.org ;;
  mainnet) CHAIN_ID=1;    RPC_URL=https://ethereum-rpc.publicnode.com; RECEIPT_RPC=https://eth.drpc.org ;;
  *) echo "usage: bash output/deploy-impl-create2.sh base|mainnet"; exit 1 ;;
esac

FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C
REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
DEPLOYER=0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF
EXPECTED_IMPL=0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231
EXPECTED_INIT_HASH=0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558
ZERO_SALT=0x0000000000000000000000000000000000000000000000000000000000000000

test "$(cast chain-id --rpc-url "$RPC_URL")" = "$CHAIN_ID" || { echo "wrong chain id"; exit 1; }

IMPL_INIT="$(forge inspect src/AdapterImplementation.sol:AdapterImplementation bytecode)$(cast abi-encode 'f(address)' "$REGISTRY" | sed 's/^0x//')"
test "$(cast keccak "$IMPL_INIT")" = "$EXPECTED_INIT_HASH" || { echo "init-code hash mismatch, build differs from the audited v0.0.17"; exit 1; }
test "$(cast create2 --deployer "$FACTORY" --salt "$ZERO_SALT" --init-code-hash "$EXPECTED_INIT_HASH")" = "$EXPECTED_IMPL" || { echo "CREATE2 address mismatch"; exit 1; }

CODE=$(cast code "$EXPECTED_IMPL" --rpc-url "$RPC_URL")
if [ "$CODE" != "0x" ]; then echo "implementation already deployed at $EXPECTED_IMPL on chain $CHAIN_ID, nothing to do"; exit 0; fi

ENV_FILE="${ENV_FILE:-/Users/nxt3d/projects/adapter/.env}"
test -f "$ENV_FILE" || { echo "env file not found: $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a
test "$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")" = "$DEPLOYER" || { echo "key in .env is not the expected deployer"; exit 1; }

echo "Chain $CHAIN_ID. Deploying AdapterImplementation v0.0.17 to $EXPECTED_IMPL via the CREATE2 factory, salt zero, registry $REGISTRY."
if [ "${CONFIRM:-}" != "yes" ]; then read -r -p "Type yes to send: " OK || OK=""; [ "$OK" = "yes" ] || { echo "aborted, rerun with CONFIRM=yes to send"; exit 1; }; fi

TX=$(cast send "$FACTORY" "${ZERO_SALT}${IMPL_INIT#0x}" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --async)
echo "sent tx $TX, waiting for the receipt"
cast receipt "$TX" --rpc-url "$RECEIPT_RPC" --confirmations 2 --json \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('status', r['status'], 'block', int(r['blockNumber'],16))"

test "$(cast code "$EXPECTED_IMPL" --rpc-url "$RECEIPT_RPC")" != "0x" || { echo "no code at the expected address after the transaction"; exit 1; }
echo "identityRegistry: $(cast call "$EXPECTED_IMPL" 'identityRegistry()(address)' --rpc-url "$RECEIPT_RPC")"
echo "proxiableUUID:    $(cast call "$EXPECTED_IMPL" 'proxiableUUID()(bytes32)' --rpc-url "$RECEIPT_RPC")"
echo "Done. The live proxy is unchanged."
