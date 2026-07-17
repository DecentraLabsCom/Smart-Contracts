#!/usr/bin/env node
'use strict';

const fs = require('fs');
const { execSync } = require('child_process');
const { ethers } = require('ethers');
const { loadSelectorManifest, validateSelectorManifest, signatureFor } = require('./selector-manifest.cjs');
require('dotenv').config();

const RPC = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const LATEST_FILE = 'deployments/sepolia-latest.json';

if (!RPC || !PRIVATE_KEY) {
  console.error('ERROR: RPC_URL and PRIVATE_KEY are required in .env');
  process.exit(1);
}

const FACETS = [
  {
    name: 'LabIntentFacet',
    contractPath: 'contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet',
    artifact: 'out/LabIntentFacet.sol/LabIntentFacet.json',
    libraryArgs: null,
  },
  {
    name: 'LabQueryFacet',
    contractPath: 'contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet',
    artifact: 'out/LabQueryFacet.sol/LabQueryFacet.json',
    libraryArgs: null,
  },
  {
    name: 'ReservationIntentFacet',
    contractPath: 'contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet',
    artifact: 'out/ReservationIntentFacet.sol/ReservationIntentFacet.json',
    libraryArgs: 'contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary',
  },
];

const DIAMOND_CUT_ABI = [
  'function diamondCut((address facetAddress, uint8 action, bytes4[] functionSelectors)[] _diamondCut, address _init, bytes _calldata)'
];

const LOUPE_ABI = [
  'function facetAddress(bytes4 _functionSelector) external view returns (address)',
  'function facetFunctionSelectors(address _facet) external view returns (bytes4[])'
];

const ACTION_ADD = 0;
const ACTION_REPLACE = 1;
const ACTION_REMOVE = 2;

function readLatest() {
  let raw = fs.readFileSync(LATEST_FILE, 'utf8');
  const first = raw.indexOf('{');
  const last = raw.lastIndexOf('}');
  if (first !== -1 && last !== -1) raw = raw.slice(first, last + 1);
  return JSON.parse(raw);
}

function writeLatest(latest) {
  fs.writeFileSync(LATEST_FILE, JSON.stringify(latest, null, 2));
}

function getArtifactSelectors(artifactPath, contractPath, manifest) {
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  const facet = manifest.facets.find((entry) => entry.target === contractPath);
  if (!facet) throw new Error(`Target is not declared in selector manifest: ${contractPath}`);
  const allowed = new Set(facet.functions);
  const selectors = [];
  for (const entry of artifact.abi || []) {
    if (entry.type !== 'function') continue;
    const sighash = signatureFor(entry);
    if (!allowed.has(sighash)) continue;
    const selector = ethers.id(sighash).slice(0, 10).toLowerCase();
    selectors.push(selector);
  }
  return [...new Set(selectors)];
}

function deployFacet(contractPath, rpc, pk, librariesArg) {
  const libs = librariesArg ? ` --libraries \"${librariesArg}\"` : '';
  const cmd = `forge create ${contractPath} --rpc-url \"${rpc}\" --private-key \"${pk}\" --broadcast${libs}`;
  const out = execSync(cmd, { encoding: 'utf8' });
  const match = out.match(/Deployed to:\s*(0x[0-9a-fA-F]{40})/);
  if (!match) {
    throw new Error(`Unable to parse deployed address for ${contractPath}`);
  }
  return { address: match[1], output: out };
}

function pushGroupedCut(groups, facetAddress, action, selector) {
  const key = `${action}:${facetAddress.toLowerCase()}`;
  if (!groups.has(key)) {
    groups.set(key, {
      facetAddress,
      action,
      functionSelectors: [],
    });
  }
  groups.get(key).functionSelectors.push(selector);
}

async function main() {
  const rootDir = __dirname + '/..';
  const selectorManifest = loadSelectorManifest(rootDir);
  const manifestValidation = validateSelectorManifest(rootDir, selectorManifest);
  if (manifestValidation.errors.length) throw new Error(manifestValidation.errors.join('\n'));
  const latest = readLatest();
  const diamondAddress = latest.contracts?.Diamond;
  if (!diamondAddress) throw new Error('Diamond address not found in deployments/sepolia-latest.json');

  const provider = new ethers.JsonRpcProvider(RPC);
  const admin = new ethers.Wallet(PRIVATE_KEY, provider);
  const loupe = new ethers.Contract(diamondAddress, LOUPE_ABI, provider);
  const diamond = new ethers.Contract(diamondAddress, DIAMOND_CUT_ABI, admin);

  console.log('Diamond:', diamondAddress);
  console.log('Admin:', admin.address);

  const rivalLib = latest.libraries?.RivalIntervalTreeLibrary;
  if (!rivalLib) throw new Error('RivalIntervalTreeLibrary address missing in deployment json');

  const deployments = {};
  for (const facet of FACETS) {
    console.log(`\nDeploying ${facet.name}...`);
    const libraries = facet.libraryArgs ? `${facet.libraryArgs}:${rivalLib}` : null;
    const result = deployFacet(facet.contractPath, RPC, PRIVATE_KEY, libraries);
    deployments[facet.name] = result.address;
    console.log(result.output);
  }

  const cutGroups = new Map();

  for (const facet of FACETS) {
    const oldFacetAddress = latest.facets?.[facet.name];
    const newFacetAddress = deployments[facet.name];
    const expectedSelectors = getArtifactSelectors(facet.artifact, facet.contractPath, selectorManifest);
    const expectedSet = new Set(expectedSelectors);

    console.log(`\nReconciling ${facet.name}`);
    console.log(' old:', oldFacetAddress || '(none)');
    console.log(' new:', newFacetAddress);
    console.log(' expected selectors:', expectedSelectors.length);

    // Ensure all expected selectors are routed to the new facet.
    for (const selector of expectedSelectors) {
      const route = (await loupe.facetAddress(selector)).toLowerCase();
      if (route === ethers.ZeroAddress.toLowerCase()) {
        pushGroupedCut(cutGroups, newFacetAddress, ACTION_ADD, selector);
      } else if (route !== newFacetAddress.toLowerCase()) {
        pushGroupedCut(cutGroups, newFacetAddress, ACTION_REPLACE, selector);
      }
    }

    // Remove stale selectors owned by the previous facet that are no longer in this ABI.
    if (oldFacetAddress && oldFacetAddress !== ethers.ZeroAddress) {
      const oldSelectors = (await loupe.facetFunctionSelectors(oldFacetAddress)).map((s) => s.toLowerCase());
      for (const selector of oldSelectors) {
        if (!expectedSet.has(selector)) {
          pushGroupedCut(cutGroups, ethers.ZeroAddress, ACTION_REMOVE, selector);
        }
      }
    }
  }

  const cut = [...cutGroups.values()].filter((entry) => entry.functionSelectors.length > 0);
  if (cut.length === 0) {
    console.log('\nNo routing changes required.');
  } else {
    console.log('\nSubmitting diamondCut with', cut.length, 'entries');
    for (const entry of cut) {
      console.log(` action=${entry.action} facet=${entry.facetAddress} selectors=${entry.functionSelectors.length}`);
    }

    const tx = await diamond.diamondCut(cut, ethers.ZeroAddress, '0x');
    console.log('diamondCut tx:', tx.hash);
    const receipt = await tx.wait();
    console.log('diamondCut confirmed in block', receipt.blockNumber);
  }

  latest.facets = latest.facets || {};
  latest.facets.LabIntentFacet = deployments.LabIntentFacet;
  latest.facets.LabQueryFacet = deployments.LabQueryFacet;
  latest.facets.ReservationIntentFacet = deployments.ReservationIntentFacet;
  latest.facets.RoutingAlignedAt = new Date().toISOString();
  writeLatest(latest);

  console.log('\nDone. Deployment file updated.');
}

main().catch((err) => {
  console.error('ERROR:', err.message || err);
  process.exit(1);
});
