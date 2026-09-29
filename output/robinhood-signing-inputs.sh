# Source from the v0.0.17 release worktree. This file performs local computation only.
# It contains no signing or broadcast operation. Prem signs the two calls in the rollout plan.
set -euo pipefail
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export PREM_DEPLOYER_ADDRESS=0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF
export FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C
export REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
export SAFE=0x03302Df40186D9B85faEA4fbb6cC5da028B23149
export VANITY_IMPL=0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231
export PROXY_SALT=0x18d9d345878344f0000000000000000b0000000000000000000000007ac92f65
export VANITY_PROXY=0x00000000003b7536DFDF148C6D9075690F8cc5A2
IMPL_CREATION=$(forge inspect src/AdapterImplementation.sol:AdapterImplementation bytecode)
REGISTRY_ARGS=$(cast abi-encode 'f(address)' "$REGISTRY")
IMPL_INIT="${IMPL_CREATION}${REGISTRY_ARGS#0x}"
test "$(cast keccak "$IMPL_INIT")" = 0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558
ZERO_SALT=0x0000000000000000000000000000000000000000000000000000000000000000
export IMPL_FACTORY_DATA="${ZERO_SALT}${IMPL_INIT#0x}"
INIT=$(cast calldata 'initialize(address)' "$SAFE")
PROXY_CREATION=$(forge inspect ERC1967Proxy bytecode)
PROXY_ARGS=$(cast abi-encode 'f(address,bytes)' "$VANITY_IMPL" "$INIT")
PROXY_INIT="${PROXY_CREATION}${PROXY_ARGS#0x}"
test "$(cast keccak "$PROXY_INIT")" = 0xbb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953
export PROXY_FACTORY_DATA="${PROXY_SALT}${PROXY_INIT#0x}"
export REGISTRY_ARGS PROXY_ARGS
python3 - <<'PY'
import os,subprocess
for salt,ih,address in [("00"*32,'5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558',os.environ['VANITY_IMPL']), (os.environ['PROXY_SALT'][2:],'bb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953',os.environ['VANITY_PROXY'])]:
 preimage='0xff'+os.environ['FACTORY'][2:]+salt+ih
 h=subprocess.check_output(['cast','keccak',preimage],text=True).strip()
 assert ('0x'+h[-40:]).lower()==address.lower()
print('Frozen hashes and CREATE2 addresses verified. No transactions sent.')
PY
