#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { ethers } = require("ethers");
require("dotenv").config();
const { loadSelectorManifest, validateSelectorManifest } = require("./selector-manifest.cjs");

const LATEST_FILE = "deployments/sepolia-latest.json";
const EXECUTE = process.argv.includes("--execute");
const VERIFY_ONLY = process.argv.includes("--verify-only");
const VERIFY = process.argv.includes("--verify") || VERIFY_ONLY;

const ACTION_ADD = 0;
const ACTION_REPLACE = 1;
const ZERO = ethers.ZeroAddress.toLowerCase();

const DIAMOND_CUT_ABI = [
  "function diamondCut((address facetAddress,uint8 action,bytes4[] functionSelectors)[] _diamondCut,address _init,bytes _calldata)",
];
const LOUPE_ABI = [
  "function facetAddress(bytes4 _functionSelector) view returns (address)",
  "function facetFunctionSelectors(address _facet) view returns (bytes4[])",
];
const OWNERSHIP_ABI = ["function owner() view returns (address)"];
const SESSION_ABI = [
  "function hasReservationSessionStarted(bytes32 reservationKey) view returns (bool)",
  "function getReservationSessionStarted(bytes32 reservationKey) view returns ((address signer,bytes32 gatewayIdHash,bytes32 sessionIdHash,bytes32 accessTypeHash,uint64 startedAt,bytes32 nonce,bytes32 credentialHash,bytes32 clientProofHash))",
];

function requireEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function redact(value) {
  const secrets = [process.env.PRIVATE_KEY, process.env.RPC_URL, process.env.ETHERSCAN_API_KEY].filter(Boolean);
  return secrets.reduce((text, secret) => text.replaceAll(secret, "[redacted]"), value || "");
}

function loadLatest() {
  const raw = fs.readFileSync(LATEST_FILE, "utf8").replace(/^\uFEFF/, "");
  return JSON.parse(raw);
}

function saveLatest(latest) {
  latest.timestamp = new Date().toISOString();
  fs.writeFileSync(LATEST_FILE, `${JSON.stringify(latest, null, 2)}\n`);
}

function forgeCreate(target, libraries = {}, nonce = undefined) {
  const args = ["create", target, "--rpc-url", requireEnv("RPC_URL"), "--private-key", requireEnv("PRIVATE_KEY"), "--broadcast"];
  if (nonce !== undefined) {
    args.push("--nonce", String(nonce));
  }
  for (const [lib, address] of Object.entries(libraries)) {
    args.push("--libraries", `${lib}:${address}`);
  }
  let out;
  try {
    out = execFileSync("forge", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    throw new Error(`forge create failed for ${target}\n${redact(`${error.stdout || ""}${error.stderr || ""}`)}`);
  }
  const match = out.match(/Deployed to:\s*(0x[0-9a-fA-F]{40})/);
  if (!match) throw new Error(`Could not parse deployment address for ${target}\n${out}`);
  return match[1];
}

function forgeVerify(address, target, libraries = {}) {
  if (!VERIFY) return;
  const apiKey = requireEnv("ETHERSCAN_API_KEY");
  const args = [
    "verify-contract",
    address,
    target,
    "--chain",
    "sepolia",
    "--verifier",
    "etherscan",
    "--etherscan-api-key",
    apiKey,
    "--skip-is-verified-check",
    "--watch",
  ];
  const libArgs = Object.entries(libraries).map(([lib, addr]) => `${lib}:${addr}`);
  if (libArgs.length > 0) {
    args.push("--libraries", libArgs.join(","));
  }
  try {
    console.log(`Verifying ${target} at ${address}...`);
    const out = execFileSync("forge", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    console.log(out.trim());
  } catch (error) {
    const output = `${error.stdout || ""}${error.stderr || ""}`;
    if (/already verified|Contract successfully verified/i.test(output)) {
      console.log(`Verified/already verified: ${target}`);
      return;
    }
    throw new Error(`Verification failed for ${target}\n${redact(output)}`);
  }
}

function manifestSelectors(manifest, target) {
  const facet = manifest.facets.find((entry) => entry.target === target);
  if (!facet) throw new Error(`Target is not declared in selector manifest: ${target}`);
  return facet.functions.map((signature) => ({
    selector: ethers.id(signature).slice(0, 10).toLowerCase(),
    signature,
  }));
}

function addCut(cutsByKey, facetAddress, action, selector, signature) {
  const key = `${action}:${facetAddress.toLowerCase()}`;
  if (!cutsByKey.has(key)) {
    cutsByKey.set(key, { facetAddress, action, functionSelectors: [], signatures: [] });
  }
  cutsByKey.get(key).functionSelectors.push(selector);
  cutsByKey.get(key).signatures.push(`${selector} ${signature}`);
}

async function main() {
  const rootDir = path.resolve(__dirname, "..");
  const selectorManifest = loadSelectorManifest(rootDir);
  const selectorValidation = validateSelectorManifest(rootDir, selectorManifest);
  if (selectorValidation.errors.length) throw new Error(selectorValidation.errors.join("\n"));
  const rpc = requireEnv("RPC_URL");
  const privateKey = requireEnv("PRIVATE_KEY");
  const latest = loadLatest();
  const diamondAddress = latest.contracts?.Diamond;
  if (!diamondAddress) throw new Error("deployments/sepolia-latest.json has no contracts.Diamond");

  const provider = new ethers.JsonRpcProvider(rpc, undefined, { batchMaxCount: 1 });
  const wallet = new ethers.Wallet(privateKey, provider);
  const network = await provider.getNetwork();
  const owner = await new ethers.Contract(diamondAddress, OWNERSHIP_ABI, provider).owner();
  if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error(`PRIVATE_KEY wallet ${wallet.address} is not Diamond owner ${owner}`);
  }

  const loupe = new ethers.Contract(diamondAddress, LOUPE_ABI, provider);
  const diamond = new ethers.Contract(diamondAddress, DIAMOND_CUT_ABI, wallet);
  const facetAddressCache = new Map();
  async function routedFacet(selector) {
    const normalized = selector.toLowerCase();
    if (!facetAddressCache.has(normalized)) {
      facetAddressCache.set(normalized, await loupe.facetAddress(normalized));
    }
    return facetAddressCache.get(normalized);
  }

  console.log(`Diamond: ${diamondAddress}`);
  console.log(`Network chainId: ${network.chainId}`);
  console.log(`Diamond owner/admin: ${wallet.address}`);
  console.log(VERIFY_ONLY ? "Mode: VERIFY ONLY" : EXECUTE ? "Mode: EXECUTE" : "Mode: DRY RUN");

  let nextNonce = EXECUTE ? await provider.getTransactionCount(wallet.address, "pending") : undefined;

  const existingRivalLib = latest.libraries?.RivalIntervalTreeLibrary;
  if (!existingRivalLib) throw new Error("RivalIntervalTreeLibrary missing in deployment file");

  const libraries = [
    { name: "LibLabTransfer", target: "contracts/libraries/LibLabTransfer.sol:LibLabTransfer", links: {} },
    {
      name: "LibReservationConfirmation",
      target: "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation",
      links: { "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary": existingRivalLib },
    },
    {
      name: "LibInstitutionalReservationConfirmation",
      target: "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation",
      links: { "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary": existingRivalLib },
    },
    {
      name: "LibInstitutionalReservationRequestValidation",
      target:
        "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation",
      links: {},
    },
    {
      name: "LibInstitutionalReservationRelease",
      target: "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease",
      links: {},
    },
  ];

  const deployedLibraries = { RivalIntervalTreeLibrary: existingRivalLib };
  for (const lib of libraries) {
    if (EXECUTE) {
      console.log(`Deploying ${lib.name}...`);
      deployedLibraries[lib.name] = forgeCreate(lib.target, lib.links, nextNonce++);
      forgeVerify(deployedLibraries[lib.name], lib.target, lib.links);
    } else {
      deployedLibraries[lib.name] = latest.libraries?.[lib.name] || ethers.ZeroAddress;
      forgeVerify(deployedLibraries[lib.name], lib.target, lib.links);
    }
    console.log(`  ${lib.name}: ${deployedLibraries[lib.name]}`);
  }

  const facetPlan = [
    {
      name: "LabFacet",
      target: "contracts/facets/lab/LabFacet.sol:LabFacet",
      artifact: "out/LabFacet.sol/LabFacet.json",
      links: { "contracts/libraries/LibLabTransfer.sol:LibLabTransfer": deployedLibraries.LibLabTransfer },
    },
    {
      name: "ProviderSettlementFacet",
      target: "contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet",
      artifact: "out/ProviderSettlementFacet.sol/ProviderSettlementFacet.json",
      links: {},
    },
    {
      name: "InstitutionalReservationRequestValidationFacet",
      target:
        "contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet",
      artifact: "out/InstitutionalReservationRequestValidationFacet.sol/InstitutionalReservationRequestValidationFacet.json",
      links: {
        "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation":
          deployedLibraries.LibInstitutionalReservationRequestValidation,
      },
    },
    {
      name: "InstitutionalReservationConfirmationFacet",
      target:
        "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet",
      artifact: "out/InstitutionalReservationConfirmationFacet.sol/InstitutionalReservationConfirmationFacet.json",
      links: {
        "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation":
          deployedLibraries.LibInstitutionalReservationConfirmation,
      },
    },
    {
      name: "InstitutionalReservationFacet",
      target: "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet",
      artifact: "out/InstitutionalReservationFacet.sol/InstitutionalReservationFacet.json",
      links: {
        "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease":
          deployedLibraries.LibInstitutionalReservationRelease,
      },
    },
    {
      name: "ReservationDenialFacet",
      target: "contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet",
      artifact: "out/ReservationDenialFacet.sol/ReservationDenialFacet.json",
      links: { "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation": deployedLibraries.LibReservationConfirmation },
    },
    {
      name: "ReservationCheckInFacet",
      target: "contracts/facets/reservation/ReservationCheckInFacet.sol:ReservationCheckInFacet",
      artifact: "out/ReservationCheckInFacet.sol/ReservationCheckInFacet.json",
      links: {},
    },
    {
      name: "ReservationSessionFacet",
      target: "contracts/facets/reservation/ReservationSessionFacet.sol:ReservationSessionFacet",
      artifact: "out/ReservationSessionFacet.sol/ReservationSessionFacet.json",
      links: {},
    },
    {
      name: "ReservationStatsFacet",
      target: "contracts/facets/reservation/ReservationStatsFacet.sol:ReservationStatsFacet",
      artifact: "out/ReservationStatsFacet.sol/ReservationStatsFacet.json",
      links: {},
    },
    {
      name: "InstitutionalReservationQueryFacet",
      target:
        "contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet",
      artifact: "out/InstitutionalReservationQueryFacet.sol/InstitutionalReservationQueryFacet.json",
      links: {},
    },
  ];

  const deployedFacets = {};
  for (const facet of facetPlan) {
    if (EXECUTE) {
      console.log(`Deploying ${facet.name}...`);
      deployedFacets[facet.name] = forgeCreate(facet.target, facet.links, nextNonce++);
      forgeVerify(deployedFacets[facet.name], facet.target, facet.links);
    } else {
      deployedFacets[facet.name] = latest.facets?.[facet.name] || ethers.ZeroAddress;
      forgeVerify(deployedFacets[facet.name], facet.target, facet.links);
    }
    console.log(`  ${facet.name}: ${deployedFacets[facet.name]}`);
  }

  if (VERIFY_ONLY) {
    console.log("Verification-only run complete.");
    return;
  }

  const cutsByKey = new Map();
  const expectedRoutes = [];
  for (const facet of facetPlan) {
    const newAddress = deployedFacets[facet.name];
    const oldAddress = latest.facets?.[facet.name] || ethers.ZeroAddress;
    const oldSelectors =
      oldAddress !== ethers.ZeroAddress
        ? new Set((await loupe.facetFunctionSelectors(oldAddress)).map((selector) => selector.toLowerCase()))
        : new Set();
    const selectors = manifestSelectors(selectorManifest, facet.target);

    console.log(`Reconciling ${facet.name}: ${selectors.length} ABI selectors, ${oldSelectors.size} old-routed selectors`);
    for (const { selector, signature } of selectors) {
      const route = (await routedFacet(selector)).toLowerCase();
      if (route === ZERO) {
        addCut(cutsByKey, newAddress, ACTION_ADD, selector, signature);
        expectedRoutes.push({ selector, signature, facet: facet.name, address: newAddress });
      } else if (oldSelectors.has(selector) && route === oldAddress.toLowerCase()) {
        addCut(cutsByKey, newAddress, ACTION_REPLACE, selector, signature);
        expectedRoutes.push({ selector, signature, facet: facet.name, address: newAddress });
      }
    }
  }

  const cuts = [...cutsByKey.values()].filter((entry) => entry.functionSelectors.length > 0);
  if (EXECUTE) {
    for (const cut of cuts) {
      if (cut.facetAddress.toLowerCase() === ZERO) {
        throw new Error(`Refusing to execute diamondCut with zero facet address for selectors: ${cut.signatures.join(", ")}`);
      }
    }
  }

  console.log("\nPlanned diamondCut:");
  for (const cut of cuts) {
    console.log(`  action=${cut.action} facet=${cut.facetAddress} selectors=${cut.functionSelectors.length}`);
    for (const signature of cut.signatures) {
      console.log(`    ${signature}`);
    }
  }

  if (cuts.length > 0 && EXECUTE) {
    const tx = await diamond.diamondCut(cuts, ethers.ZeroAddress, "0x", { nonce: nextNonce++ });
    console.log(`diamondCut tx: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`diamondCut confirmed in block ${receipt.blockNumber}`);
  }

  if (EXECUTE) {
    for (const route of expectedRoutes) {
      const actual = await loupe.facetAddress(route.selector);
      if (actual.toLowerCase() !== route.address.toLowerCase()) {
        throw new Error(`${route.signature} selector ${route.selector} expected ${route.address}, got ${actual}`);
      }
    }

    const session = new ethers.Contract(diamondAddress, SESSION_ABI, provider);
    const emptyKey = `0x${"0".repeat(64)}`;
    const hasStarted = await session.hasReservationSessionStarted(emptyKey);
    await session.getReservationSessionStarted(emptyKey);
    console.log(`SessionStarted read validation ok. Empty key hasSessionStarted=${hasStarted}`);

    latest.libraries = latest.libraries || {};
    for (const lib of libraries) latest.libraries[lib.name] = deployedLibraries[lib.name];
    latest.facets = latest.facets || {};
    for (const facet of facetPlan) latest.facets[facet.name] = deployedFacets[facet.name];
    latest.facets.CheckInUpgradeAt = new Date().toISOString();
    saveLatest(latest);
    console.log(`Updated ${LATEST_FILE}`);
  }
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
