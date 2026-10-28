#!/usr/bin/env node
// Transfer ownership of WrappedBNSv2 and WrappedENS to a multisig on Base mainnet.
//
// Usage:
//   DEPLOYER_PRIVATE_KEY=0x... \
//   NEW_OWNER=0x09cbc0d92aabe6f53ac7e84f0ba0fbfd05eb80f2 \
//   node script/transfer-external-ownership.js
//
// NEW_OWNER defaults to the Safe multisig address below if not set.

const { ethers } = require("ethers");

const RPC_URL  = "https://mainnet.base.org";
const MULTISIG = "0x09cbc0d92aabe6f53ac7e84f0ba0fbfd05eb80f2";

const CONTRACTS = [
  { label: "WrappedBNSv2", address: "0xa98741B7EE20B096a6262A705A088f8c0563Dfa4" },
  { label: "WrappedENS",   address: "0xC7AFf3b228b8353d1811802F90f389815431a194" },
];

const OWNABLE_ABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address newOwner)",
];

async function main() {
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!privateKey) throw new Error("DEPLOYER_PRIVATE_KEY env var is required");

  const newOwner = process.env.NEW_OWNER ?? MULTISIG;

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(privateKey, provider);

  const { chainId } = await provider.getNetwork();
  console.log(`Connected to Base mainnet (chainId ${chainId})`);
  console.log(`Signer : ${wallet.address}`);
  console.log(`New owner (multisig): ${newOwner}\n`);

  for (const { label, address } of CONTRACTS) {
    console.log(`--- ${label} (${address}) ---`);
    const contract = new ethers.Contract(address, OWNABLE_ABI, wallet);

    const currentOwner = await contract.owner();
    console.log(`  current owner : ${currentOwner}`);

    if (currentOwner.toLowerCase() !== wallet.address.toLowerCase()) {
      console.error(`  ERROR: signer is not the current owner — skipping`);
      continue;
    }

    if (currentOwner.toLowerCase() === newOwner.toLowerCase()) {
      console.log(`  already owned by multisig — skipping`);
      continue;
    }

    process.stdout.write(`  broadcasting transferOwnership...`);
    const tx = await contract.transferOwnership(newOwner);
    console.log(` tx hash: ${tx.hash}`);

    process.stdout.write(`  waiting for confirmation...`);
    const receipt = await tx.wait(1);
    console.log(` confirmed in block ${receipt.blockNumber} (status: ${receipt.status === 1 ? "SUCCESS" : "REVERTED"})\n`);
  }

  console.log("Done.");
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
