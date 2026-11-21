#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {execFileSync} = require("node:child_process");
const {ethers} = require("ethers");
require("dotenv").config();
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const ROOT = path.resolve(__dirname, "..");
const LATEST_FILE = path.join(ROOT, "deployments", "sepolia-latest.json");
const BROADCAST = process.argv.includes("--broadcast");
const CHAIN_ID = 11155111n;
const ZERO_ADDRESS = ethers.ZeroAddress;
const DIAMOND_ABI = [
  "function owner() view returns (address)",
  "function facetAddresses() view returns (address[])",
  "function facetAddress(bytes4 selector) view returns (address)",
  "function facetFunctionSelectors(address facet) view returns (bytes4[])",
  "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] cuts,address init,bytes calldata)",
];
const TARGETS = [
  {
    name: "ReservationIntentFacet",
    target: "contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet",
    artifact: "out/ReservationIntentFacet.sol/ReservationIntentFacet.json",
    oldAddressKey: "ReservationIntentFacet",
    links: {},
  },
  {
    name: "InstitutionalReservationConfirmationFacet",
    target: "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet",
    artifact: "out/InstitutionalReservationConfirmationFacet.sol/InstitutionalReservationConfirmationFacet.json",
    oldAddressKey: "InstitutionalReservationConfirmationFacet",
    links: {},
  },
];
const LIBRARY = {
  name: "LibInstitutionalReservationConfirmation",
  target: "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation",
  artifact: "out/LibInstitutionalReservationConfirmation.sol/LibInstitutionalReservationConfirmation.json",
};

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

function requiredEnv(name) {
  if (!process.env[name]) throw new Error(`${name} is required in the environment or .env`);
  return process.env[name];
}

function selectorsFor(manifest, target) {
  const facet = manifest.facets.find((entry) => entry.target === target);
  if (!facet) throw new Error(`Target is missing from selectors/diamond.json: ${target}`);
  return facet.functions.map((signature) => ({
    signature,
    selector: ethers.id(signature).slice(0, 10).toLowerCase(),
  }));
}

function sameSet(left, right) {
  const normalized = (values) => [...values].map((value) => value.toLowerCase()).sort();
  return JSON.stringify(normalized(left)) === JSON.stringify(normalized(right));
}

function artifactFor(relativePath) {
  const artifactPath = path.join(ROOT, relativePath);
  if (!fs.existsSync(artifactPath)) throw new Error(`Missing Foundry artifact: ${relativePath}; run forge build first`);
  return readJson(artifactPath);
}

function linkBytecode(artifact, suppliedLibraries = {}) {
  let bytecode = artifact.bytecode.object.replace(/^0x/, "");
  const references = artifact.bytecode.linkReferences || {};
  const unresolved = [];
  for (const [source, libraries] of Object.entries(references)) {
    for (const [name, locations] of Object.entries(libraries)) {
      const address = suppliedLibraries[`${source}:${name}`];
      if (!address || !ethers.isAddress(address)) {
        unresolved.push(`${source}:${name}`);
        continue;
      }
      const replacement = ethers.getAddress(address).slice(2).toLowerCase();
      for (const {start, length} of locations) {
        if (length !== 20) throw new Error(`Unexpected link width for ${source}:${name}`);
        const offset = start * 2;
        if (bytecode.slice(offset, offset + length * 2).length !== length * 2) {
          throw new Error(`Link reference is outside bytecode bounds for ${source}:${name}`);
        }
        bytecode = `${bytecode.slice(0, offset)}${replacement}${bytecode.slice(offset + length * 2)}`;
      }
    }
  }
  if (unresolved.length) throw new Error(`Unresolved library references: ${unresolved.join(", ")}`);
  if (bytecode.includes("__$") || bytecode.includes("__")) throw new Error("Artifact bytecode still has unresolved library placeholders");
  return `0x${bytecode}`;
}

function buildDeploymentArtifacts() {
  try {
    const output = execFileSync("forge", ["build", "--optimizer-runs", "1"], {
      cwd: ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 20 * 1024 * 1024,
    });
    const summary = output.split(/\r?\n/).filter((line) => /^(Compiling |No files changed|Solc .* finished|Compiler run successful)/.test(line));
    console.log(summary.slice(-3).join("\n") || "Foundry deployment build completed.");
  } catch (error) {
    const output = `${error.stdout || ""}\n${error.stderr || ""}`;
    const relevant = output.split(/\r?\n/).filter((line) => line.trim()).slice(-12).join("\n");
    throw new Error(`forge build --optimizer-runs 1 failed${relevant ? `:\n${relevant}` : ""}`);
  }
}

async function deploy(signer, artifact, bytecode, label) {
  const factory = new ethers.ContractFactory(artifact.abi, bytecode, signer);
  const contract = await factory.deploy();
  const transaction = contract.deploymentTransaction();
  if (!transaction) throw new Error(`No deployment transaction created for ${label}`);
  console.log(`${label} deployment submitted: ${transaction.hash}`);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  if ((await signer.provider.getCode(address)) === "0x") throw new Error(`${label} has no code after deployment`);
  console.log(`${label}: ${address}`);
  return address;
}

async function main() {
  if (BROADCAST) {
    buildDeploymentArtifacts();
  }

  const latest = readJson(LATEST_FILE);
  if (latest.network !== "sepolia" || BigInt(latest.chainId) !== CHAIN_ID) {
    throw new Error(`Refusing deployment artifact network/chain: ${latest.network}/${latest.chainId}`);
  }
  const diamondAddress = latest.contracts?.Diamond;
  if (!ethers.isAddress(diamondAddress)) throw new Error("deployments/sepolia-latest.json has no valid Diamond address");

  const selectorManifest = loadSelectorManifest(ROOT);
  const validation = validateSelectorManifest(ROOT, selectorManifest);
  if (validation.errors.length) throw new Error(validation.errors.join("\n"));

  const rpc = requiredEnv("RPC_URL");
  const provider = new ethers.JsonRpcProvider(rpc, undefined, {batchMaxCount: 1});
  const network = await provider.getNetwork();
  if (network.chainId !== CHAIN_ID) throw new Error(`RPC is chain ${network.chainId}, expected Sepolia ${CHAIN_ID}`);
  if ((await provider.getCode(diamondAddress)) === "0x") throw new Error(`Diamond has no code: ${diamondAddress}`);

  const loupe = new ethers.Contract(diamondAddress, DIAMOND_ABI, provider);
  const owner = await loupe.owner();
  const expectedOwner = latest.deployer;
  if (!ethers.isAddress(expectedOwner) || owner.toLowerCase() !== expectedOwner.toLowerCase()) {
    throw new Error(`Live Diamond owner ${owner} does not match deployment owner ${expectedOwner}`);
  }

  const plans = TARGETS.map((target) => ({...target, selectors: selectorsFor(selectorManifest, target.target)}));
  const initialFacetAddresses = await loupe.facetAddresses();
  for (const plan of plans) {
    const oldAddress = latest.facets?.[plan.oldAddressKey];
    if (!ethers.isAddress(oldAddress)) throw new Error(`Missing old facet address for ${plan.name} in latest deployment`);
    const expected = plan.selectors.map(({selector}) => selector);
    const oldFacetSelectors = await loupe.facetFunctionSelectors(oldAddress);
    if (!sameSet(oldFacetSelectors, expected)) {
      throw new Error(`Live selectors on ${plan.name} ${oldAddress} do not exactly match selectors/diamond.json`);
    }
    for (const {selector, signature} of plan.selectors) {
      const route = await loupe.facetAddress(selector);
      if (route.toLowerCase() !== oldAddress.toLowerCase()) {
        throw new Error(`${signature} routes to ${route}, expected current ${plan.name} ${oldAddress}`);
      }
    }
  }

  console.log(`Diamond: ${diamondAddress}`);
  console.log(`Chain: Sepolia (${network.chainId})`);
  console.log(`Owner: ${owner}`);
  for (const plan of plans) {
    console.log(`${plan.name}: replacing ${plan.selectors.length} selectors from ${latest.facets[plan.oldAddressKey]}`);
    for (const {selector, signature} of plan.selectors) console.log(`  ${selector} ${signature}`);
  }

  if (!BROADCAST) {
    console.log("Read-only preflight passed. Add --broadcast to deploy linked facets and apply the two replacements atomically.");
    return;
  }

  const signer = new ethers.Wallet(requiredEnv("PRIVATE_KEY"), provider);
  if (signer.address.toLowerCase() !== owner.toLowerCase()) {
    throw new Error(`Broadcast signer ${signer.address} is not Diamond owner ${owner}`);
  }
  const existingRivalLibrary = latest.libraries?.RivalIntervalTreeLibrary;
  if (!ethers.isAddress(existingRivalLibrary) || (await provider.getCode(existingRivalLibrary)) === "0x") {
    throw new Error("The existing RivalIntervalTreeLibrary address is missing or has no live code");
  }

  const libraryArtifact = artifactFor(LIBRARY.artifact);
  const libraryLinks = {
    "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary": existingRivalLibrary,
  };
  const libraryBytecode = linkBytecode(libraryArtifact, libraryLinks);
  const deployEstimates = [];
  const libraryFactory = new ethers.ContractFactory(libraryArtifact.abi, libraryBytecode, signer);
  deployEstimates.push(await provider.estimateGas({
    from: signer.address,
    ...(await libraryFactory.getDeployTransaction()),
  }));
  const facetArtifacts = new Map();
  for (const plan of plans) {
    const artifact = artifactFor(plan.artifact);
    for (const signature of plan.selectors.map(({signature}) => signature)) {
      if (!new ethers.Interface(artifact.abi).getFunction(signature)) {
        throw new Error(`${plan.name} artifact does not expose manifest function ${signature}`);
      }
    }
    const estimateLinks = plan.name === "InstitutionalReservationConfirmationFacet"
      ? {"contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation": "0x0000000000000000000000000000000000000001"}
      : {};
    const bytecode = linkBytecode(artifact, estimateLinks);
    const factory = new ethers.ContractFactory(artifact.abi, bytecode, signer);
    deployEstimates.push(await provider.estimateGas({from: signer.address, ...(await factory.getDeployTransaction())}));
    facetArtifacts.set(plan.name, artifact);
  }
  const feeData = await provider.getFeeData();
  const feePerGas = feeData.maxFeePerGas || feeData.gasPrice;
  if (!feePerGas) throw new Error("RPC did not provide a gas price for the deployment preflight");
  const reserve = ((deployEstimates.reduce((sum, value) => sum + value, 750_000n) * feePerGas) * 120n) / 100n;
  const balance = await provider.getBalance(signer.address);
  console.log(`Estimated max transaction reserve (including cut and 20% margin): ${ethers.formatEther(reserve)} ETH`);
  console.log(`Owner balance: ${ethers.formatEther(balance)} ETH`);
  if (balance < reserve) throw new Error("Diamond owner balance is below the estimated upgrade reserve; no deployment was sent");

  const newLibraryAddress = await deploy(
    signer,
    libraryArtifact,
    libraryBytecode,
    LIBRARY.name,
  );
  const deployedFacets = new Map();
  for (const plan of plans) {
    const artifact = facetArtifacts.get(plan.name);
    const links = plan.name === "InstitutionalReservationConfirmationFacet"
      ? {"contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation": newLibraryAddress}
      : {};
    const facetAddress = await deploy(signer, artifact, linkBytecode(artifact, links), plan.name);
    deployedFacets.set(plan.name, facetAddress);
  }

  const cuts = plans.map((plan) => ({
    facetAddress: deployedFacets.get(plan.name),
    action: 1,
    functionSelectors: plan.selectors.map(({selector}) => selector),
  }));
  const diamond = new ethers.Contract(diamondAddress, DIAMOND_ABI, signer);
  await diamond.diamondCut.staticCall(cuts, ZERO_ADDRESS, "0x");
  console.log("Diamond cut simulation succeeded; submitting one atomic replacement transaction.");
  const transaction = await diamond.diamondCut(cuts, ZERO_ADDRESS, "0x");
  console.log(`diamondCut submitted: ${transaction.hash}`);
  const receipt = await transaction.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`diamondCut failed: ${transaction.hash}`);

  for (const plan of plans) {
    const address = deployedFacets.get(plan.name);
    const expected = plan.selectors.map(({selector}) => selector);
    const actualSelectors = await loupe.facetFunctionSelectors(address);
    if (!sameSet(actualSelectors, expected)) throw new Error(`Post-cut loupe selector mismatch for ${plan.name}`);
    for (const {selector, signature} of plan.selectors) {
      const route = await loupe.facetAddress(selector);
      if (route.toLowerCase() !== address.toLowerCase()) throw new Error(`Post-cut route mismatch for ${signature}: ${route}`);
    }
  }
  const expectedFacetAddresses = initialFacetAddresses
    .filter((address) => !plans.some((plan) => latest.facets[plan.oldAddressKey].toLowerCase() === address.toLowerCase()))
    .concat([...deployedFacets.values()]);
  const actualFacetAddresses = await loupe.facetAddresses();
  if (!sameSet(actualFacetAddresses, expectedFacetAddresses)) {
    throw new Error("Post-cut loupe facet address set differs from the two expected replacements");
  }

  const block = await provider.getBlock(receipt.blockNumber);
  const timestamp = block ? new Date(Number(block.timestamp) * 1000).toISOString() : new Date().toISOString();
  latest.timestamp = timestamp;
  latest.upgrade = {transaction: receipt.hash, block: receipt.blockNumber, timestamp};
  latest.libraries[LIBRARY.name] = newLibraryAddress;
  for (const plan of plans) latest.facets[plan.name] = deployedFacets.get(plan.name);
  const snapshotPath = path.join(ROOT, "deployments", `sepolia-${timestamp.replace(/[:.]/g, "-")}.json`);
  fs.writeFileSync(snapshotPath, `${JSON.stringify(latest, null, 2)}\n`);
  fs.writeFileSync(LATEST_FILE, `${JSON.stringify(latest, null, 2)}\n`);
  console.log(`Cut mined and loupe verified in block ${receipt.blockNumber}: ${receipt.hash}`);
  console.log(`Deployment snapshot: ${path.relative(ROOT, snapshotPath)}`);
  console.log(`Updated latest deployment: ${path.relative(ROOT, LATEST_FILE)}`);

  execFileSync(process.execPath, [path.join(__dirname, "sync-backend-deployment-manifest.cjs")], {
    cwd: ROOT,
    stdio: "inherit",
  });
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
