#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {ethers} = require("ethers");
require("dotenv").config({quiet: true});
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const LOUPE_ABI = [
  "function facets() view returns ((address facetAddress,bytes4[] functionSelectors)[])",
];
const OWNER_ABI = ["function owner() view returns (address)"];
const CUT_ABI = [
  "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] diamondCut,address init,bytes calldata_)",
];

async function main() {
  const rootDir = path.resolve(__dirname, "..");
  const deployment = JSON.parse(
    fs.readFileSync(path.join(rootDir, "deployments", "sepolia-latest.json"), "utf8"),
  );
  const manifest = loadSelectorManifest(rootDir);
  const validation = validateSelectorManifest(rootDir, manifest);
  if (validation.errors.length) throw new Error(validation.errors.join("\n"));

  const rpcUrl = process.env.RPC_URL;
  if (!rpcUrl) throw new Error("RPC_URL is required");
  const diamondAddress = deployment.contracts?.Diamond;
  if (!ethers.isAddress(diamondAddress)) throw new Error("deployments/sepolia-latest.json has no valid Diamond");

  const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, {batchMaxCount: 1});
  const loupe = new ethers.Contract(diamondAddress, LOUPE_ABI, provider);
  const liveFacets = await loupe.facets();
  const desiredSelectors = new Set(validation.allowedSelectors.keys());
  const forbiddenBySelector = new Map(
    manifest.forbiddenFunctions.map((signature) => [ethers.id(signature).slice(0, 10).toLowerCase(), signature]),
  );
  const liveSelectors = Array.from(liveFacets).flatMap((facet) =>
    Array.from(facet.functionSelectors, (selector) => selector.toLowerCase()),
  );
  const removals = liveSelectors.filter((selector) => !desiredSelectors.has(selector)).sort();
  const missing = [...desiredSelectors].filter((selector) => !liveSelectors.includes(selector)).sort();

  console.log(`Diamond: ${diamondAddress}`);
  console.log(`Live selectors: ${liveSelectors.length}`);
  console.log(`Manifest selectors: ${desiredSelectors.size}`);
  console.log(`Remove: ${removals.length}; missing: ${missing.length}`);
  for (const selector of removals) {
    console.log(`  REMOVE ${selector} ${forbiddenBySelector.get(selector) || "<unclassified>"}`);
  }
  for (const selector of missing) {
    console.log(`  MISSING ${selector} ${validation.allowedSelectors.get(selector)}`);
  }

  if (removals.length === 0) return;
  const cuts = [{facetAddress: ethers.ZeroAddress, action: 2, functionSelectors: removals}];
  const iface = new ethers.Interface(CUT_ABI);
  const calldata = iface.encodeFunctionData("diamondCut", [cuts, ethers.ZeroAddress, "0x"]);
  console.log(`Removal calldata: ${calldata}`);

  if (process.argv.includes("--simulate")) {
    const ownership = new ethers.Contract(diamondAddress, OWNER_ABI, provider);
    const owner = await ownership.owner();
    await provider.call({to: diamondAddress, from: owner, data: calldata});
    console.log(`Simulation successful from Diamond owner ${owner}; no transaction was broadcast.`);
  }
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
