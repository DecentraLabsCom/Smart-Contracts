#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {execFileSync} = require("node:child_process");
const {ethers} = require("ethers");
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const LOCAL_CHAIN_ID = 31_337n;
const LOCAL_RPC = process.env.LOCAL_FORK_RPC_URL || "http://127.0.0.1:8546";
const LOCAL_DEPLOYER_KEY =
  process.env.LOCAL_FORK_DEPLOYER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

function deploy(rootDir, target, libraries = {}) {
  const args = ["create", target, "--rpc-url", LOCAL_RPC, "--private-key", LOCAL_DEPLOYER_KEY, "--broadcast"];
  for (const [library, address] of Object.entries(libraries)) {
    args.push("--libraries", `${library}:${address}`);
  }
  const output = execFileSync("forge", args, {cwd: rootDir, encoding: "utf8"});
  const match = output.match(/Deployed to:\s*(0x[0-9a-fA-F]{40})/);
  if (!match) throw new Error(`Could not parse deployment address for ${target}\n${output}`);
  return ethers.getAddress(match[1]);
}

async function rawCall(provider, diamond, signature, args = []) {
  const iface = new ethers.Interface([`function ${signature}`]);
  return provider.call({to: diamond, data: iface.encodeFunctionData(signature.slice(0, signature.indexOf("(")), args)});
}

async function main() {
  const rootDir = path.resolve(__dirname, "..");
  const manifest = loadSelectorManifest(rootDir);
  const validation = validateSelectorManifest(rootDir, manifest);
  if (validation.errors.length) throw new Error(validation.errors.join("\n"));

  const provider = new ethers.JsonRpcProvider(LOCAL_RPC, undefined, {batchMaxCount: 1});
  const network = await provider.getNetwork();
  if (network.chainId !== LOCAL_CHAIN_ID) {
    throw new Error(`Refusing to run outside a local fork (expected chainId ${LOCAL_CHAIN_ID}, got ${network.chainId})`);
  }

  const deployment = JSON.parse(
    fs.readFileSync(path.join(rootDir, "deployments", "sepolia-latest.json"), "utf8"),
  );
  const diamondAddress = deployment.contracts.Diamond;
  const ownerContract = new ethers.Contract(diamondAddress, ["function owner() view returns (address)"], provider);
  const owner = await ownerContract.owner();
  const snapshots = new Map();
  const snapshotCalls = [
    ["owner() view returns (address)"],
    ["hasRole(bytes32,address) view returns (bool)", [ethers.ZeroHash, owner]],
    ["getLabProvidersPaginated(uint256,uint256) view returns (tuple(address account,tuple(string name,string email,string country,string authURI) base)[],uint256)", [0, 1]],
    ["totalBalanceOf(address) view returns (uint256)", [owner]],
    ["name() view returns (string)"],
    ["getLabCount() view returns (uint256)"],
  ];
  for (const [signature, args] of snapshotCalls) {
    snapshots.set(signature, await rawCall(provider, diamondAddress, signature, args));
  }

  const labTransfer = deployment.libraries.LibLabTransfer;
  const denialLibrary = deploy(
    rootDir,
    "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation",
  );
  const plans = [
    {
      name: "ProviderFacet",
      address: deploy(rootDir, "contracts/facets/ProviderFacet.sol:ProviderFacet"),
    },
    {
      name: "ServiceCreditFacet",
      address: deploy(rootDir, "contracts/facets/ServiceCreditFacet.sol:ServiceCreditFacet"),
    },
    {
      name: "InstitutionFacet",
      address: deploy(
        rootDir,
        "contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet",
      ),
    },
    {
      name: "InstitutionalReservationRequestCreationFacet",
      address: deploy(
        rootDir,
        "contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet",
      ),
    },
    {
      name: "LabFacet",
      address: deploy(rootDir, "contracts/facets/lab/LabFacet.sol:LabFacet", {
        "contracts/libraries/LibLabTransfer.sol:LibLabTransfer": labTransfer,
      }),
    },
    {
      name: "ReservationDenialFacet",
      address: deploy(rootDir, "contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet", {
        "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation": denialLibrary,
      }),
    },
  ];
  for (const plan of plans) console.log(`Deployed ${plan.name}: ${plan.address}`);

  const loupe = new ethers.Contract(
    diamondAddress,
    [
      "function facets() view returns ((address facetAddress,bytes4[] functionSelectors)[])",
      "function facetAddress(bytes4) view returns (address)",
    ],
    provider,
  );
  const liveBefore = Array.from(await loupe.facets()).flatMap((facet) => Array.from(facet.functionSelectors));
  const desired = new Set(validation.allowedSelectors.keys());
  const removals = liveBefore.map((selector) => selector.toLowerCase()).filter((selector) => !desired.has(selector));
  const cuts = plans.map((plan) => {
    const facet = manifest.facets.find((entry) => entry.name === plan.name);
    if (!facet) throw new Error(`Missing manifest facet ${plan.name}`);
    return {
      facetAddress: plan.address,
      action: 1,
      functionSelectors: facet.functions.map((signature) => ethers.id(signature).slice(0, 10)),
    };
  });
  if (removals.length > 0) {
    cuts.push({facetAddress: ethers.ZeroAddress, action: 2, functionSelectors: removals});
  }
  console.log(`Fork state before cut: ${liveBefore.length} selectors; removing ${removals.length}.`);

  await provider.send("anvil_setBalance", [owner, "0x3635C9ADC5DEA00000"]);
  await provider.send("anvil_impersonateAccount", [owner]);
  const ownerSigner = await provider.getSigner(owner);
  const diamondCut = new ethers.Contract(
    diamondAddress,
    ["function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[],address,bytes)"],
    ownerSigner,
  );
  const cutData = diamondCut.interface.encodeFunctionData("diamondCut", [cuts, ethers.ZeroAddress, "0x"]);
  try {
    await provider.call({to: diamondAddress, from: owner, data: cutData});
  } catch (error) {
    console.error(`Cut simulation failed: ${error.shortMessage || error.message}`);
    console.error(`Revert data: ${error.data || error.info?.error?.data || "unavailable"}`);
    throw error;
  }
  const transaction = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x", {gasLimit: 15_000_000});
  await transaction.wait();
  await provider.send("anvil_stopImpersonatingAccount", [owner]);

  const liveAfter = Array.from(await loupe.facets()).flatMap((facet) => Array.from(facet.functionSelectors));
  if (liveAfter.length !== desired.size) {
    throw new Error(`Expected ${desired.size} selectors after cut, got ${liveAfter.length}`);
  }
  for (const plan of plans) {
    const facet = manifest.facets.find((entry) => entry.name === plan.name);
    for (const signature of facet.functions) {
      const selector = ethers.id(signature).slice(0, 10);
      const route = await loupe.facetAddress(selector);
      if (route.toLowerCase() !== plan.address.toLowerCase()) {
        throw new Error(`${signature} routed to ${route}, expected ${plan.address}`);
      }
    }
  }
  for (const selector of removals) {
    if ((await loupe.facetAddress(selector)) !== ethers.ZeroAddress) {
      throw new Error(`Removed selector ${selector} is still routed`);
    }
  }
  for (const [signature, args] of snapshotCalls) {
    const after = await rawCall(provider, diamondAddress, signature, args);
    if (after !== snapshots.get(signature)) throw new Error(`State changed across upgrade for ${signature}`);
  }

  const creation = new ethers.Interface([
    "function createInstReservation((address,address,uint256,uint32,uint32,bytes32,bytes32,address))",
    "function recordRecentInstReservation(uint256,address,bytes32,uint32)",
  ]);
  const deployer = new ethers.Wallet(LOCAL_DEPLOYER_KEY, provider);
  const guardedCalls = [
    creation.encodeFunctionData("createInstReservation", [[
      deployer.address,
      deployer.address,
      1,
      1,
      2,
      ethers.ZeroHash,
      ethers.ZeroHash,
      deployer.address,
    ]]),
    creation.encodeFunctionData("recordRecentInstReservation", [1, deployer.address, ethers.ZeroHash, 1]),
  ];
  for (const data of guardedCalls) {
    let reverted = false;
    try {
      await provider.call({to: diamondAddress, from: deployer.address, data});
    } catch {
      reverted = true;
    }
    if (!reverted) throw new Error("An internal reservation helper accepted an external call after upgrade");
  }

  console.log(`Local fork upgrade passed: ${liveBefore.length} -> ${liveAfter.length} selectors.`);
  console.log(`Replaced ${plans.length} facets, removed ${removals.length} selectors, preserved ${snapshots.size} state reads.`);
  console.log("Both internal reservation helper calls reverted for an external caller.");
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
