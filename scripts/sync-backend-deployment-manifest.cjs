#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const {ethers} = require("ethers");
require("dotenv").config();
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const ROOT = path.resolve(__dirname, "..");
const LATEST_FILE = path.join(ROOT, "deployments", "sepolia-latest.json");
const BACKEND_REPO = path.resolve(ROOT, "..", "Lab Gateway", "blockchain-services");
const BACKEND_MANIFEST = path.join(
  BACKEND_REPO,
  "src",
  "main",
  "resources",
  "contract",
  "deployment-manifest.json",
);
const BACKEND_ABI = path.join(BACKEND_REPO, "abi", "Diamond.json");
const BACKEND_SELECTOR_MANIFEST = path.join(
  BACKEND_REPO,
  "src",
  "main",
  "resources",
  "contract",
  "selector-manifest.json",
);
const CHECK_ONLY = process.argv.includes("--check");
const DIAMOND_ABI = [
  "function owner() view returns (address)",
  "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role,address account) view returns (bool)",
  "function facetAddresses() view returns (address[])",
  "function facetFunctionSelectors(address facet) view returns (bytes4[])",
];

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function assertConsumerInSync(source, consumer, label) {
  if (!fs.existsSync(consumer)) throw new Error(`Missing canonical backend ${label}: ${consumer}`);
  const normalizeNewlines = (value) => value.replace(/\r\n/g, "\n");
  if (normalizeNewlines(fs.readFileSync(source, "utf8")) !== normalizeNewlines(fs.readFileSync(consumer, "utf8"))) {
    throw new Error(`Backend ${label} differs from the Smart-Contracts source; run npm run abi:sync-consumers first`);
  }
}

function compareSets(left, right) {
  const normalize = (values) => [...values].map((value) => value.toLowerCase()).sort();
  return JSON.stringify(normalize(left)) === JSON.stringify(normalize(right));
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  if (typeof value === "string" && /^0x[0-9a-fA-F]+$/.test(value)) return value.toLowerCase();
  return value;
}

function stableManifest(value) {
  return stable({
    ...value,
    facets: [...(value.facets || [])].sort((left, right) => left.name.localeCompare(right.name)),
  });
}

function addressForFacet(deployment, name) {
  const address = deployment.facets?.[name] || deployment.contracts?.[name];
  if (!ethers.isAddress(address)) throw new Error(`Deployment snapshot has no valid address for facet ${name}`);
  return ethers.getAddress(address);
}

async function codeHash(provider, address, label) {
  const code = await provider.getCode(address);
  if (!code || code === "0x") throw new Error(`${label} has no live code at ${address}`);
  return ethers.keccak256(code);
}

async function main() {
  if (!process.env.RPC_URL) throw new Error("RPC_URL is required in the environment or .env");
  if (!fs.existsSync(path.join(BACKEND_REPO, "pom.xml"))) {
    throw new Error("Canonical Lab Gateway/blockchain-services checkout is missing; refusing to create a backend path");
  }
  const deployment = readJson(LATEST_FILE);
  assertConsumerInSync(path.join(ROOT, "abi", "Diamond.json"), BACKEND_ABI, "Diamond ABI");
  assertConsumerInSync(path.join(ROOT, "selectors", "diamond.json"), BACKEND_SELECTOR_MANIFEST, "selector manifest");
  const selectorManifest = loadSelectorManifest(ROOT);
  const validation = validateSelectorManifest(ROOT, selectorManifest);
  if (validation.errors.length) throw new Error(validation.errors.join("\n"));

  const diamondAddress = deployment.contracts?.Diamond;
  const diamondInitAddress = deployment.contracts?.DiamondInit;
  if (!ethers.isAddress(diamondAddress) || !ethers.isAddress(diamondInitAddress)) {
    throw new Error("Latest deployment must contain valid Diamond and DiamondInit addresses");
  }

  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL, undefined, {batchMaxCount: 1});
  const network = await provider.getNetwork();
  if (network.chainId !== BigInt(deployment.chainId)) {
    throw new Error(`RPC chain ID ${network.chainId} does not match deployment chain ID ${deployment.chainId}`);
  }
  const diamond = new ethers.Contract(diamondAddress, DIAMOND_ABI, provider);
  const owner = await diamond.owner();
  if (deployment.deployer && owner.toLowerCase() !== deployment.deployer.toLowerCase()) {
    throw new Error(`Live Diamond owner ${owner} differs from deployment owner ${deployment.deployer}`);
  }
  const defaultAdminRole = await diamond.DEFAULT_ADMIN_ROLE();
  if (!(await diamond.hasRole(defaultAdminRole, owner))) {
    throw new Error(`Live Diamond owner ${owner} does not hold DEFAULT_ADMIN_ROLE`);
  }

  const expectedFacets = selectorManifest.facets.map((facet) => ({
    name: facet.name,
    address: addressForFacet(deployment, facet.name),
    selectors: facet.functions.map((signature) => ethers.id(signature).slice(0, 10).toLowerCase()),
  }));
  const actualFacetAddresses = await diamond.facetAddresses();
  if (!compareSets(actualFacetAddresses, expectedFacets.map(({address}) => address))) {
    throw new Error("Live Diamond facet address set does not match the deployment snapshot");
  }

  const facets = [];
  for (const expected of expectedFacets) {
    const actualSelectors = await diamond.facetFunctionSelectors(expected.address);
    if (!compareSets(actualSelectors, expected.selectors)) {
      throw new Error(`Live selectors for ${expected.name} do not match selectors/diamond.json`);
    }
    facets.push({
      name: expected.name,
      address: expected.address,
      codeHash: await codeHash(provider, expected.address, `Facet ${expected.name}`),
    });
  }

  const existing = fs.existsSync(BACKEND_MANIFEST) ? readJson(BACKEND_MANIFEST) : {};
  const manifest = {
    schemaVersion: existing.schemaVersion || 1,
    deploymentState: "active",
    network: deployment.network,
    chainId: Number(network.chainId),
    abiVersion: process.env.CONTRACT_ABI_VERSION || existing.abiVersion || "credit-ledger-v1",
    abiSha256: sha256(BACKEND_ABI),
    selectorManifestSha256: sha256(BACKEND_SELECTOR_MANIFEST),
    diamondAddress: ethers.getAddress(diamondAddress),
    expectedOwner: owner.toLowerCase(),
    expectedDefaultAdminRole: defaultAdminRole,
    criticalAddresses: {DiamondInit: ethers.getAddress(diamondInitAddress)},
    criticalCodeHashes: {
      [ethers.getAddress(diamondAddress)]: await codeHash(provider, diamondAddress, "Diamond"),
      [ethers.getAddress(diamondInitAddress)]: await codeHash(provider, diamondInitAddress, "DiamondInit"),
    },
    facets,
  };

  if (CHECK_ONLY) {
    if (!fs.existsSync(BACKEND_MANIFEST)) throw new Error(`Backend manifest does not exist: ${BACKEND_MANIFEST}`);
    const current = readJson(BACKEND_MANIFEST);
    if (JSON.stringify(stableManifest(current)) !== JSON.stringify(stableManifest(manifest))) {
      const fields = [...new Set([...Object.keys(current), ...Object.keys(manifest)])]
        .filter((key) => JSON.stringify(stable(current[key])) !== JSON.stringify(stable(manifest[key])));
      const currentFacets = new Map((current.facets || []).map((facet) => [facet.name, facet]));
      const facetDifferences = manifest.facets
        .filter((facet) => JSON.stringify(stable(currentFacets.get(facet.name))) !== JSON.stringify(stable(facet)))
        .map((facet) => facet.name);
      throw new Error(`Backend manifest is stale in: ${fields.join(", ")}${facetDifferences.length ? ` (${facetDifferences.join(", ")})` : ""}`);
    }
    console.log("Backend deployment manifest matches the live Diamond.");
    return;
  }

  fs.mkdirSync(path.dirname(BACKEND_MANIFEST), {recursive: true});
  const output = JSON.stringify(manifest, null, 2).replace(
    /    \{\n      "name": "([^"]+)",\n      "address": "([^"]+)",\n      "codeHash": "([^"]+)"\n    \}/g,
    '    { "name": "$1", "address": "$2", "codeHash": "$3" }',
  );
  fs.writeFileSync(BACKEND_MANIFEST, `${output}\n`);
  console.log(`Synchronized live deployment manifest: ${path.relative(ROOT, BACKEND_MANIFEST)}`);
  console.log(`Diamond: ${manifest.diamondAddress}; facets verified: ${manifest.facets.length}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
