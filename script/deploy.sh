#!/usr/bin/env bash
set -euo pipefail

# 1. Require a supported target network name.
NETWORK="${1:-}"
if [[ -z "$NETWORK" ]]; then
  echo "usage: script/deploy.sh [base|mainnet|sepolia]"
  exit 1
fi

# 2. Refuse chains that already run an adapter proxy, before any configuration or key is read.
#    Those proxies upgrade in place: build the Safe payload with script/PrepareChainUpgrade.s.sol
#    and execute it through the Safe. This script is only for a chain with no adapter yet.
case "$NETWORK" in
  base)    EXISTING_PROXY="0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27" ;;
  mainnet) EXISTING_PROXY="0xde152AfB7db5373F34876E1499fbD893A82dD336" ;;
  sepolia) EXISTING_PROXY="0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92" ;;
  *)       EXISTING_PROXY="" ;;
esac
if [[ -n "$EXISTING_PROXY" ]]; then
  echo "refusing: an adapter proxy already exists on $NETWORK at $EXISTING_PROXY"
  echo "a fresh deployment would create a second, deployer-owned proxy"
  echo "to upgrade the existing proxy, use script/PrepareChainUpgrade.s.sol and execute the payload through the Safe"
  exit 1
fi

# 3. Load local deployment configuration from .env when present.
if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source ".env"
fi

# 4. Map the requested network to its RPC URL and ERC-8004 registry env vars.
case "$NETWORK" in
  base)
    RPC_URL="${BASE_RPC_URL:-}"
    IDENTITY_REGISTRY_ADDRESS="${BASE_IDENTITY_REGISTRY_ADDRESS:-}"
    ;;
  mainnet)
    RPC_URL="${MAINNET_RPC_URL:-}"
    IDENTITY_REGISTRY_ADDRESS="${MAINNET_IDENTITY_REGISTRY_ADDRESS:-}"
    ;;
  sepolia)
    RPC_URL="${SEPOLIA_RPC_URL:-}"
    IDENTITY_REGISTRY_ADDRESS="${SEPOLIA_IDENTITY_REGISTRY_ADDRESS:-}"
    ;;
  *)
    echo "unsupported network: $NETWORK"
    echo "supported networks: base, mainnet, sepolia"
    exit 1
    ;;
esac

# 5. Refuse to run without the required deployment configuration.
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "missing DEPLOYER_PRIVATE_KEY in environment"
  exit 1
fi

if [[ -z "$RPC_URL" ]]; then
  echo "missing RPC URL for network: $NETWORK"
  exit 1
fi

if [[ -z "$IDENTITY_REGISTRY_ADDRESS" ]]; then
  echo "missing identity registry address for network: $NETWORK"
  exit 1
fi

# 6. Export the exact env vars the Foundry deployment script expects.
export DEPLOYER_PRIVATE_KEY
export IDENTITY_REGISTRY_ADDRESS

# 7. Broadcast the adapter implementation and proxy deployment to the selected chain.
forge script script/DeployAdapter.s.sol:DeployAdapterScript --rpc-url "$RPC_URL" --broadcast
