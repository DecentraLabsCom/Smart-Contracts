#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {ethers} = require("ethers");
require("dotenv").config({quiet: true});

const DIRECT_RESERVATION_SIGNATURE =
  "institutionalReservationRequest(address,bytes32,uint256,uint32,uint32)";
const DIRECT_RESERVATION_SELECTOR = ethers.id(DIRECT_RESERVATION_SIGNATURE).slice(0, 10).toLowerCase();
const ZERO_ADDRESS = ethers.ZeroAddress;
const LOUPE_ABI = [
  "function facetAddress(bytes4) view returns (address)",
  "function owner() view returns (address)",
];
const CUT_ABI = [
  "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] diamondCut,address init,bytes calldata_)",
];

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function buildRemovalCut() {
  return [{
    facetAddress: ZERO_ADDRESS,
    action: 2,
    functionSelectors: [DIRECT_RESERVATION_SELECTOR],
  }];
}

function deploymentDiamond(rootDir) {
  const file = path.join(rootDir, "deployments", "sepolia-latest.json");
  return JSON.parse(fs.readFileSync(file, "utf8")).contracts?.Diamond;
}

async function main() {
  const rootDir = path.resolve(__dirname, "..");
  const rpcUrl = argumentValue("--rpc") || process.env.RPC_URL;
  const diamondAddress = argumentValue("--diamond") || deploymentDiamond(rootDir);
  const shouldSimulate = process.argv.includes("--simulate");
  const shouldBroadcast = process.argv.includes("--broadcast");

  if (!rpcUrl) throw new Error("RPC_URL is required");
  if (!ethers.isAddress(diamondAddress)) throw new Error("Diamond address is invalid");
  if (shouldSimulate && shouldBroadcast) throw new Error("Choose --simulate or --broadcast, not both");

  const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, {batchMaxCount: 1});
  const loupe = new ethers.Contract(diamondAddress, LOUPE_ABI, provider);
  const currentFacet = await loupe.facetAddress(DIRECT_RESERVATION_SELECTOR);
  const owner = await loupe.owner();
  const iface = new ethers.Interface(CUT_ABI);
  const calldata = iface.encodeFunctionData("diamondCut", [
    buildRemovalCut(),
    ZERO_ADDRESS,
    "0x",
  ]);

  console.log(`Diamond: ${diamondAddress}`);
  console.log(`Selector: ${DIRECT_RESERVATION_SELECTOR}`);
  console.log(`Current facet: ${currentFacet}`);
  console.log(`Owner: ${owner}`);
  console.log(`Removal calldata: ${calldata}`);

  if (currentFacet === ZERO_ADDRESS) {
    console.log("Selector is already removed; no transaction is required.");
    return;
  }

  if (shouldSimulate || shouldBroadcast) {
    await provider.call({to: diamondAddress, from: owner, data: calldata});
    console.log("Diamond owner simulation succeeded.");
  }

  if (!shouldBroadcast) {
    console.log("Plan only; no transaction was broadcast.");
    return;
  }

  if (!process.env.PRIVATE_KEY) throw new Error("PRIVATE_KEY is required for --broadcast");
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  if (signer.address.toLowerCase() !== owner.toLowerCase()) {
    throw new Error("PRIVATE_KEY does not belong to the Diamond owner");
  }

  const transaction = await signer.sendTransaction({to: diamondAddress, data: calldata});
  console.log(`Transaction: ${transaction.hash}`);
  await transaction.wait();

  const remainingFacet = await loupe.facetAddress(DIRECT_RESERVATION_SELECTOR);
  if (remainingFacet !== ZERO_ADDRESS) throw new Error(`Selector still routes to ${remainingFacet}`);
  console.log("Selector removal confirmed.");
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message || error);
    process.exitCode = 1;
  });
}

module.exports = {
  DIRECT_RESERVATION_SIGNATURE,
  DIRECT_RESERVATION_SELECTOR,
  buildRemovalCut,
};
