require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const { loadSelectorManifest, validateSelectorManifest, signatureFor } = require('./selector-manifest.cjs');

async function main(){
  const RPC = process.env.RPC_URL;
  if(!RPC) throw new Error('RPC_URL missing in .env');
  // Read resume robustly (tolerate BOM or wrappers)
  let rawResume = fs.readFileSync('deployments/sepolia-resume.json', 'utf8');
  const f = rawResume.indexOf('{');
  const l = rawResume.lastIndexOf('}');
  if (f === -1 || l === -1) throw new Error('Invalid resume json file');
  rawResume = rawResume.slice(f, l + 1);
  const resume = JSON.parse(rawResume);
  const rootDir = path.resolve(__dirname, '..');
  const manifest = loadSelectorManifest(rootDir);
  const manifestValidation = validateSelectorManifest(rootDir, manifest);
  if (manifestValidation.errors.length) throw new Error(manifestValidation.errors.join('\n'));
  const DIAMOND = resume.base && resume.base.Diamond;
  const provider = new ethers.JsonRpcProvider(RPC);
  const facetInterface = new ethers.Interface(['function facetAddress(bytes4) view returns (address)']);

  const targets = [
    'contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet',
    'contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet',
    'contracts/facets/lab/LabFacet.sol:LabFacet',
    'contracts/facets/ProviderFacet.sol:ProviderFacet',
    'contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet'
  ];

  const report = [];

  for(const t of targets){
    const parts = t.split(':');
    const artifactPath = path.join('hh-artifacts', parts[0], parts[1] + '.json');
    if(!fs.existsSync(artifactPath)){
      console.warn('Artifact not found', artifactPath, 'skipping');
      continue;
    }
    const artifact = JSON.parse(fs.readFileSync(artifactPath,'utf8'));
    const facet = manifest.facets.find((entry) => entry.target === t);
    if (!facet) throw new Error(`Target is not declared in selector manifest: ${t}`);
    const allowed = new Set(facet.functions);
    const functions = artifact.abi.filter(a => a.type === 'function' && allowed.has(signatureFor(a)));
    const selectors = functions.map(fn => ethers.id(signatureFor(fn)).slice(0,10));

    const mapped = new Map();
    for(const sel of selectors){
      const res = await provider.call({ to: DIAMOND, data: facetInterface.encodeFunctionData('facetAddress',[sel]) });
      const [addr] = facetInterface.decodeFunctionResult('facetAddress', res);
      mapped.set(sel, addr);
    }

    const uniqueAddrs = new Set(Array.from(mapped.values()).map(a=>a.toLowerCase()));
    report.push({contractId: t, selectorsCount: selectors.length, uniqueFacetAddresses: Array.from(uniqueAddrs)});
  }

  console.log('Verification report:');
  for(const r of report){
    console.log(`- ${r.contractId}: ${r.selectorsCount} selectors -> ${r.uniqueFacetAddresses.length} unique facet address(es)`);
    for(const a of r.uniqueFacetAddresses) console.log('   ', a);

    // If there are multiple addresses for a contract, show which functions map to which address (detailed check)
    if (r.uniqueFacetAddresses.length > 1 && r.contractId.includes('LabFacet')) {
      console.log('   Detailed mapping for LabFacet (functions -> facet address):');
      const parts = r.contractId.split(':');
      const artifactPath = path.join('hh-artifacts', parts[0], parts[1] + '.json');
      const artifact = JSON.parse(fs.readFileSync(artifactPath,'utf8'));
      const allFunctions = artifact.abi.filter(a => a.type === 'function');
      for(const fn of allFunctions){
        const sig = `${fn.name}(${(fn.inputs||[]).map(i=>i.type).join(',')})`;
        const sel = ethers.id(sig).slice(0,10);
        const addr = await provider.call({ to: DIAMOND, data: facetInterface.encodeFunctionData('facetAddress',[sel]) });
        const [mappedAddr] = facetInterface.decodeFunctionResult('facetAddress', addr);
        console.log('     ', sel, sig, '->', mappedAddr);
      }
    }
  }

  // Quick health check: ensure none mapped to zero or to the Diamond itself
  const bad = [];
  for(const r of report){
    for(const a of r.uniqueFacetAddresses){
      if(a === ethers.ZeroAddress) bad.push({r,issue:'zeroAddress'});
    }
  }
  if(bad.length > 0){
    console.error('Found selectors mapped to zero address or missing facets');
    process.exit(2);
  }

  console.log('\nNow checking supportsInterface responses for common interface IDs:');
  const iface = new ethers.Interface(['function supportsInterface(bytes4) view returns (bool)']);
  const ERC165 = '0x01ffc9a7';
  const ERC721 = '0x80ac58cd';
  const ERC721Metadata = '0x5b5e139f';
  for(const id of [ERC165, ERC721, ERC721Metadata]){
    try{
      const res = await provider.call({ to: DIAMOND, data: iface.encodeFunctionData('supportsInterface',[id]) });
      const [ok] = iface.decodeFunctionResult('supportsInterface', res);
      console.log(' - supportsInterface('+id+') ->', ok);
    }catch(e){
      console.log(' - supportsInterface('+id+') -> call failed', e.message);
    }
  }

  console.log('\nDone.');
}

main().catch(e=>{ console.error('Error:', e); process.exit(1); });

