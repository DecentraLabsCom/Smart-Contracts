#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function readJsonRobust(p) {
  let raw = fs.readFileSync(p, 'utf8');
  const first = raw.indexOf('{');
  const last = raw.lastIndexOf('}');
  if (first === -1 || last === -1) throw new Error('Invalid json file: ' + p);
  raw = raw.slice(first, last + 1);
  return JSON.parse(raw);
}

async function main() {
  const args = process.argv.slice(2);
  const rpc = args[args.indexOf('--rpc') + 1] || process.env.RPC_URL;
  const diamond = args[args.indexOf('--diamond') + 1] || process.env.DIAMOND || '0x7189d48be3e0e3d86A783B50b4D9Cf5DaEb8815c';
  const throttleMs = Number(args[args.indexOf('--throttle-ms') + 1] || process.env.VERIFY_THROTTLE_MS || 50);
  const maxRetries = Number(args[args.indexOf('--retries') + 1] || process.env.VERIFY_RETRIES || 6);
  const retryBaseMs = Number(args[args.indexOf('--retry-base-ms') + 1] || process.env.VERIFY_RETRY_BASE_MS || 250);
  const resumePath = path.join(__dirname, '..', 'deployments', 'sepolia-resume.json');
  const includeUnmapped = args.includes('--include-unmapped');
  if (!rpc) {
    console.error('Usage: node scripts/verify-all-facets-selectors.js --rpc <RPC_URL> [--diamond <address>] [--broadcast --private-key <KEY>]');
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(rpc);
  const resume = readJsonRobust(resumePath);
  const facetsMap = resume.facets || {};

  // Walk hh-artifacts/contracts/facets recursively
  const facetsRoot = path.join(__dirname, '..', 'hh-artifacts', 'contracts', 'facets');

  const iface = new ethers.Interface(["function facetAddress(bytes4) view returns (address)"]);

  const mismatches = [];
  const cutsPerTarget = {}; // targetAddress -> { add: Set, replace: Set }
  const selectorsByFacet = {}; // facetAddress -> Set<selectors>
  const selectorsToFacets = {}; // selector -> Set<facetAddress>

  function ensureTarget(t) {
    if (!cutsPerTarget[t]) cutsPerTarget[t] = { add: new Set(), replace: new Set() };
    return cutsPerTarget[t];
  }

  function collectArtifacts(dir, out) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) collectArtifacts(p, out);
      else if (e.isFile() && e.name.endsWith('.json')) out.push(p);
    }
  }

  function isRetryable(err) {
    const msg = String(err && err.message ? err.message : '');
    const code = err && err.code;
    const nestedCode = err && err.info && err.info.error && err.info.error.code;
    if (code === 'UNKNOWN_ERROR' || code === 'CALL_EXCEPTION') {
      if (msg.toLowerCase().includes('rate') || msg.toLowerCase().includes('limit')) return true;
    }
    if (nestedCode === -32005 || nestedCode === 429) return true;
    if (code === -32005 || code === 429) return true;
    return false;
  }

  async function withRetry(fn, label) {
    let attempt = 0;
    while (true) {
      try {
        return await fn();
      } catch (err) {
        attempt += 1;
        if (!isRetryable(err) || attempt > maxRetries) {
          throw err;
        }
        const waitMs = Math.min(retryBaseMs * Math.pow(2, attempt - 1), 4000);
        console.warn(`Retrying ${label} in ${waitMs}ms (attempt ${attempt}/${maxRetries})`);
        await sleep(waitMs);
      }
    }
  }

  function getCanonicalType(node) {
    if (!node || !node.type) return '';
    if (node.type.startsWith('tuple')) {
      const suffix = node.type.slice(5);
      const components = (node.components || []).map(getCanonicalType);
      return `(${components.join(',')})${suffix}`;
    }
    return node.type;
  }

  function addSelector(facetAddress, selector) {
    if (!selectorsByFacet[facetAddress]) selectorsByFacet[facetAddress] = new Set();
    selectorsByFacet[facetAddress].add(selector);
    if (!selectorsToFacets[selector]) selectorsToFacets[selector] = new Set();
    selectorsToFacets[selector].add(facetAddress);
  }

  async function processArtifact(artifactPath, facetAddress) {
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    if (!artifact.abi || !artifact.contractName || !artifact.sourceName) return;
    const resumeKey = `${artifact.sourceName}:${artifact.contractName}`;
    const expectedAddressRaw = facetsMap[resumeKey];
    const expectedAddress = expectedAddressRaw ? ethers.getAddress(expectedAddressRaw) : null;
    if (!expectedAddress && !includeUnmapped) return;
    const targetAddress = facetAddress || expectedAddress;
    if (!targetAddress) return;

    const functions = artifact.abi.filter(a => a.type === 'function');
    for (const fn of functions) {
      const sig = `${fn.name}(${(fn.inputs || []).map(getCanonicalType).join(',')})`;
      // compute selector
      const selector = ethers.id(sig).slice(0, 10);
      addSelector(targetAddress, selector);
    }
  }

  console.log('Scanning facet artifacts under', facetsRoot);
  const artifacts = [];
  collectArtifacts(facetsRoot, artifacts);
  const artifactByKey = {};
  for (const artifactPath of artifacts) {
    try {
      const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
      if (!artifact.abi || !artifact.contractName || !artifact.sourceName) continue;
      const resumeKey = `${artifact.sourceName}:${artifact.contractName}`;
      if (facetsMap[resumeKey]) artifactByKey[resumeKey] = artifactPath;
    } catch {
      // ignore
    }
  }

  const resumeKeys = includeUnmapped ? Object.keys(artifactByKey) : Object.keys(facetsMap);
  for (const resumeKey of resumeKeys) {
    const artifactPath = artifactByKey[resumeKey];
    if (!artifactPath) continue;
    try {
      await processArtifact(artifactPath, facetsMap[resumeKey] ? ethers.getAddress(facetsMap[resumeKey]) : null);
    } catch (err) {
      console.error('Error processing', artifactPath, err);
    }
  }

  const selectors = Object.keys(selectorsToFacets);
  for (const selector of selectors) {
    const data = iface.encodeFunctionData('facetAddress', [selector]);
    const res = await withRetry(() => provider.call({ to: diamond, data }), 'facetAddress');
    const [current] = iface.decodeFunctionResult('facetAddress', res);
    const candidates = Array.from(selectorsToFacets[selector] || []);

    if (!current || current === ethers.ZeroAddress) {
      mismatches.push({ selector, expected: candidates, current: ethers.ZeroAddress, action: candidates.length === 1 ? 'add' : '' });
      if (candidates.length === 1) ensureTarget(candidates[0]).add.add(selector);
    } else {
      const normalizedCurrent = ethers.getAddress(current);
      const match = selectorsByFacet[normalizedCurrent] && selectorsByFacet[normalizedCurrent].has(selector);
      if (!match) {
        const action = candidates.length === 1 ? 'replace' : '';
        mismatches.push({ selector, expected: candidates, current: normalizedCurrent, action });
        if (candidates.length === 1) ensureTarget(candidates[0]).replace.add(selector);
      }
    }

    if (throttleMs > 0) await sleep(throttleMs);
  }

  if (mismatches.length === 0) {
    console.log('\nNo mismatches detected across facets.');
    process.exit(0);
  }

  console.log('\nFound mismatches/changes needed (sample):');
  console.table(mismatches.slice(0, 50));

  // Build cuts
  const facetCuts = [];
  for (const [target, lists] of Object.entries(cutsPerTarget)) {
    const adds = Array.from(lists.add);
    const replaces = Array.from(lists.replace);
    if (adds.length > 0) {
      facetCuts.push({ facetAddress: target, action: 0, functionSelectors: adds });
    }
    if (replaces.length > 0) {
      facetCuts.push({ facetAddress: target, action: 1, functionSelectors: replaces });
    }
  }

  if (facetCuts.length === 0) {
    console.log('\nNo actionable cuts prepared (mismatches may be unfixable automatically).');
    process.exit(0);
  }

  const dcIface = new ethers.Interface(['function diamondCut((address,uint8,bytes4[])[],address,bytes)']);
  const tupleCuts = facetCuts.map(c => [c.facetAddress, c.action, c.functionSelectors]);
  const calldata = dcIface.encodeFunctionData('diamondCut', [tupleCuts, ethers.ZeroAddress, '0x']);

  console.log('\nPrepared the following facet cuts:');
  console.log(JSON.stringify(facetCuts, null, 2));
  console.log('\nCalldata:');
  console.log(calldata);

  // If broadcast requested
  if (args.includes('--broadcast')) {
    const keyIndex = args.indexOf('--private-key');
    if (keyIndex === -1) { console.error('Broadcast requested but no --private-key provided'); process.exit(1); }
    const key = args[keyIndex + 1];
    const wallet = new ethers.Wallet(key, provider);
    console.log('Broadcasting diamondCut transaction as', wallet.address);
    const tx = await wallet.sendTransaction({ to: diamond, data: calldata, gasLimit: 1_000_000 });
    console.log('Sent tx:', tx.hash);
    const rcpt = await tx.wait();
    console.log('Tx confirmed in block', rcpt.blockNumber);

    // Re-verify changed selectors
    console.log('\nRe-verifying mappings after broadcast...');
    // Simple re-scan: just print results for selectors in facetCuts
    for (const cut of facetCuts) {
      for (const sel of cut.functionSelectors) {
        const data = iface.encodeFunctionData('facetAddress', [sel]);
        const res = await provider.call({ to: diamond, data });
        const [current] = iface.decodeFunctionResult('facetAddress', res);
        console.log(sel, '->', current);
      }
    }
  }
}

main().catch(e => { console.error(e); process.exit(1); });
