#!/usr/bin/env node
/*
 * Redeploy failed facets and replace them in the Diamond via diamondCut
 * Usage: node scripts/redeploy-and-replace-facets.js --rpc <RPC_URL> --diamond <DIAMOND_ADDR> --private-key <KEY>
 *
 * The script will:
 *  - compile using `forge build`
 *  - deploy each target contract with `forge create` (linking RivalIntervalTreeLibrary if required)
 *  - prepare a diamondCut replacing all selectors of the old facet addresses with the new address
 *  - send the diamondCut transaction and wait for confirmation
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const { loadSelectorManifest, validateSelectorManifest, signatureFor } = require('./selector-manifest.cjs');
require('dotenv').config();

function parseArgs() {
  const a = process.argv.slice(2);
  const out = {};
  for (let i = 0; i < a.length; i++) {
    if (a[i] === '--rpc') out.rpc = a[++i];
    else if (a[i] === '--diamond') out.diamond = a[++i];
    else if (a[i] === '--private-key') out.key = a[++i];
    else if (a[i] === '--force') out.force = true;
  }
  return out;
}

async function main() {
  const argv = parseArgs();
  const RPC = argv.rpc || process.env.RPC_URL;
  const DIAMOND = argv.diamond || (process.env.DEPLOY_RESUME_FILE ? JSON.parse(fs.readFileSync(process.env.DEPLOY_RESUME_FILE)).base.Diamond : null) || '0x7189d48be3e0e3d86A783B50b4D9Cf5DaEb8815c';
  const PRIVATE_KEY = argv.key || process.env.PRIVATE_KEY;
  if (!RPC || !DIAMOND || !PRIVATE_KEY) {
    console.error('Missing arguments: --rpc, --diamond and --private-key (or set RPC_URL/PRIVATE_KEY in .env)');
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log('Using wallet', wallet.address);

  // failed facets to redeploy: map of contract id -> resume key (to find old address)
  const targets = [
    { contract: 'contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet' },
    { contract: 'contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet' },
    { contract: 'contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet' },
    { contract: 'contracts/facets/lab/LabFacet.sol:LabFacet' },
    { contract: 'contracts/facets/ProviderFacet.sol:ProviderFacet' }
  ];

  // library linking if needed
  // Read resume robustly (tolerate BOM or wrappers)
  let rawResume = fs.readFileSync('deployments/sepolia-resume.json', 'utf8');
  const f = rawResume.indexOf('{');
  const l = rawResume.lastIndexOf('}');
  if (f === -1 || l === -1) throw new Error('Invalid resume json file');
  rawResume = rawResume.slice(f, l + 1);
  const resume = JSON.parse(rawResume);
  const libraryAddr = resume.base && resume.base.RivalIntervalTreeLibrary;
  const needsLibraryNames = new Set([
    'ProviderSettlementFacet', 'ReservationIntentFacet', 'LabFacet'
  ]);

  console.log('\n1) Compiling with forge build...');
  execSync('forge build', { stdio: 'inherit' });
  const selectorManifest = loadSelectorManifest(path.resolve(__dirname, '..'));
  const manifestValidation = validateSelectorManifest(path.resolve(__dirname, '..'), selectorManifest);
  if (manifestValidation.errors.length) throw new Error(manifestValidation.errors.join('\n'));
  const manifestByTarget = new Map(selectorManifest.facets.map((facet) => [facet.target, new Set(facet.functions)]));

  const deployed = [];

  for (const t of targets) {
    const parts = t.contract.split(':');
    const contractName = parts[1];
    console.log(`\nDeploying ${contractName}...`);

    const libFlag = needsLibraryNames.has(contractName) && libraryAddr ? `--libraries "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary:${libraryAddr}"` : '';

    // Add --broadcast to actually send the deploy tx
    const cmd = `forge create ${t.contract} --rpc-url ${RPC} --private-key ${PRIVATE_KEY} --broadcast ${libFlag}`;
    console.log('Running:', cmd);
    const out = execSync(cmd, { encoding: 'utf8' });
    // parse "Deployed to: 0x..."
    const m = out.match(/Deployed to:\s*(0x[a-fA-F0-9]{40})/);
    if (!m) {
      console.error('Failed to deploy', contractName, '\nOutput:\n', out);
      process.exit(1);
    }
    const newAddr = m[1];
    console.log(`${contractName} -> ${newAddr}`);
    // find old address from resume (if present)
    const resumeKey = t.contract;
    const oldAddr = resume.facets && resume.facets[resumeKey];
    deployed.push({ contractId: t.contract, name: contractName, oldAddr: oldAddr || null, newAddr });
  }

  // Prepare diamondCut: for each deployed contract, replace all selectors that currently point to oldAddr to point to newAddr
  console.log('\n2) Building diamondCut replacement cuts...');

  const dcIface = new ethers.Interface(['function diamondCut((address,uint8,bytes4[])[],address,bytes)']);
  const facetInterface = new ethers.Interface(['function facetAddress(bytes4) view returns (address)']);
  const cuts = [];

  for (const d of deployed) {
    // read artifact for this contract from hh-artifacts
    let artifactPath = path.join('hh-artifacts', d.contractId.replace(':', path.sep) + '.json');
    if (!fs.existsSync(artifactPath)) {
      throw new Error(`Artifact not found for ${d.contractId}: ${artifactPath}`);
    }
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    const allowedFunctions = manifestByTarget.get(d.contractId);
    if (!allowedFunctions) throw new Error(`Target is not declared in selector manifest: ${d.contractId}`);
    const functions = artifact.abi.filter(a => a.type === 'function' && allowedFunctions.has(signatureFor(a)));
    const selectors = functions.map(fn => {
      const sig = signatureFor(fn);
      return ethers.id(sig).slice(0,10);
    });

    console.log(`${d.name}: selectors count ${selectors.length}`);

    // Query current mapping for each selector and decide action
    const toAdd = [];
    const toReplace = [];
    for (const sel of selectors) {
      const res = await provider.call({ to: DIAMOND, data: facetInterface.encodeFunctionData('facetAddress', [sel]) });
      const [current] = facetInterface.decodeFunctionResult('facetAddress', res);
      if (current === ethers.ZeroAddress) {
        toAdd.push(sel);
      } else if (current.toLowerCase() === d.newAddr.toLowerCase()) {
        // already correct, skip
      } else if (current.toLowerCase() === DIAMOND.toLowerCase()) {
        throw new Error(`Selector ${sel} is implemented in the Diamond (immutable) - cannot replace`);
      } else {
        toReplace.push(sel);
      }
    }

    if (toAdd.length > 0) cuts.push([d.newAddr, 0, toAdd]);
    if (toReplace.length > 0) cuts.push([d.newAddr, 1, toReplace]);
  }

  // Canonical selectors mapping: ensure critical selectors end up in the preferred facet
  // Selector -> preferred contractId (artifact key)
  const CANONICAL = {
    // ERC-165
    '0x01ffc9a7': 'contracts/facets/lab/LabFacet.sol:LabFacet',
    // ERC-721
    '0x80ac58cd': 'contracts/facets/lab/LabFacet.sol:LabFacet',
    // ERC-721 metadata
    '0x5b5e139f': 'contracts/facets/lab/LabFacet.sol:LabFacet'
  };

  // Ensure canonical selectors are forced to point to the preferred facet address by adding replace cuts
  for (const [sel, preferredContractId] of Object.entries(CANONICAL)) {
    // Use the deployment from this run, or persisted resume state when continuing an interrupted run.
    const desiredEntry = deployed.find(d => d.contractId === preferredContractId);
    let desiredAddr = desiredEntry ? desiredEntry.newAddr : (resume.facets && resume.facets[preferredContractId]) || null;
    if (!desiredAddr) {
      console.warn('Canonical preferred facet', preferredContractId, 'not deployed or not present in resume; skipping canonical enforcement for', sel);
      continue;
    }

    // Add a replace cut to ensure the selector maps to desiredAddr (action = 1)
    const alreadyPlanned = cuts.some(c => c[1] === 1 && c[2].includes(sel));
    if (!alreadyPlanned) {
      console.log('Enforcing canonical selector', sel, '->', desiredAddr);
      cuts.push([desiredAddr, 1, [sel]]);
    }
  }

  if (cuts.length === 0) {
    console.log('Nothing to cut. Exiting.');
    process.exit(0);
  }

  const calldata = dcIface.encodeFunctionData('diamondCut', [cuts, ethers.ZeroAddress, '0x']);
  console.log('\nCalldata length', calldata.length, 'preview:', calldata.slice(0,200));

  console.log('\n3) Sending diamondCut transaction to replace old facets with new ones...');
  const tx = await wallet.sendTransaction({ to: DIAMOND, data: calldata, gasLimit: 1500000 });
  console.log('Sent diamondCut tx:', tx.hash);
  const rcpt = await tx.wait();
  console.log('diamondCut confirmed in block', rcpt.blockNumber);

  // Post-upgrade check: validate canonical selectors now point to the preferred facets
  console.log('\n4) Validating canonical selectors post-upgrade...');
  for (const [sel, preferredContractId] of Object.entries(CANONICAL)) {
    const res = await provider.call({ to: DIAMOND, data: facetInterface.encodeFunctionData('facetAddress', [sel]) });
    const [current] = facetInterface.decodeFunctionResult('facetAddress', res);
    // resolve desired address again
    const desiredEntry = deployed.find(d => d.contractId === preferredContractId);
    const desiredAddr = desiredEntry ? desiredEntry.newAddr : (resume.facets && resume.facets[preferredContractId]) || null;
    console.log(' - selector', sel, 'expected ->', desiredAddr, 'actual ->', current);
    if (!desiredAddr) {
      console.warn('   No desired address known for', sel, '; cannot assert canonical mapping.');
      continue;
    }
    if (current.toLowerCase() !== desiredAddr.toLowerCase()) {
      console.error('Canonical mapping failed for selector', sel, ': expected', desiredAddr, 'but got', current);
      throw new Error('Canonical selector validation failed after diamondCut');
    }
  }

  // Verify selectors now point to new addresses (sample)
  console.log('\n5) Verifying a sample of selectors map to new facets...');
  for (const d of deployed) {
    const artifactPath = path.join('hh-artifacts', d.contractId.replace(':', path.sep) + '.json');
    if (!fs.existsSync(artifactPath)) continue;
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    const allowedFunctions = manifestByTarget.get(d.contractId);
    const functions = artifact.abi.filter(a => a.type === 'function' && allowedFunctions?.has(signatureFor(a)));
    if (functions.length === 0) continue;
    const selector = ethers.id(signatureFor(functions[0])).slice(0,10);
    const data = facetInterface.encodeFunctionData('facetAddress', [selector]);
    const res = await provider.call({ to: DIAMOND, data });
    const [current] = facetInterface.decodeFunctionResult('facetAddress', res);
    console.log(d.name, 'selector', selector, '->', current);
  }

  console.log('\nDone. Deployed and replaced facets:');
  console.table(deployed);
}

main().catch(e => { console.error('Error:', e); process.exit(1); });

