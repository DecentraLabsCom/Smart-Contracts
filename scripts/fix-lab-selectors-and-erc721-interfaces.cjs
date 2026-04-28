#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
require('dotenv').config();

function readJsonFile(filePath) {
  const content = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  return JSON.parse(content);
}

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--rpc') out.rpc = args[++i];
    else if (args[i] === '--diamond') out.diamond = args[++i];
    else if (args[i] === '--private-key') out.key = args[++i];
    else if (args[i] === '--dry-run') out.dryRun = true;
  }
  return out;
}

async function main() {
  const argv = parseArgs();
  const RPC = argv.rpc || process.env.RPC_URL;
  const PRIVATE_KEY = argv.key || process.env.PRIVATE_KEY;
  const DIAMOND = argv.diamond
    || (process.env.DEPLOY_RESUME_FILE
      ? readJsonFile(process.env.DEPLOY_RESUME_FILE).base.Diamond
      : null);

  if (!RPC || !PRIVATE_KEY || !DIAMOND) {
    console.error('Usage: node scripts/fix-lab-selectors-and-erc721-interfaces.js --rpc <RPC_URL> --diamond <DIAMOND_ADDR> --private-key <KEY> [--dry-run]');
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  const loupeIface = new ethers.Interface([
    'function facetAddress(bytes4) view returns (address)',
    'function supportsInterface(bytes4) view returns (bool)'
  ]);
  const dcIface = new ethers.Interface([
    'function diamondCut((address,uint8,bytes4[])[],address,bytes)'
  ]);

  const GHOST_SELECTORS = ['0x4f6ccce7', '0x2f745c59', '0x18160ddd'];
  const IERC721_ID = '0x80ac58cd';
  const IERC721_METADATA_ID = '0x5b5e139f';

  console.log('Using wallet:', wallet.address);
  console.log('Diamond:', DIAMOND);

  const toRemove = [];
  for (const sel of GHOST_SELECTORS) {
    const res = await provider.call({
      to: DIAMOND,
      data: loupeIface.encodeFunctionData('facetAddress', [sel])
    });
    const [currentFacet] = loupeIface.decodeFunctionResult('facetAddress', res);
    console.log(`selector ${sel} -> ${currentFacet}`);
    if (currentFacet !== ethers.ZeroAddress) {
      toRemove.push(sel);
    }
  }

  const erc721Res = await provider.call({
    to: DIAMOND,
    data: loupeIface.encodeFunctionData('supportsInterface', [IERC721_ID])
  });
  const [supports721] = loupeIface.decodeFunctionResult('supportsInterface', erc721Res);

  const erc721MetaRes = await provider.call({
    to: DIAMOND,
    data: loupeIface.encodeFunctionData('supportsInterface', [IERC721_METADATA_ID])
  });
  const [supports721Metadata] = loupeIface.decodeFunctionResult('supportsInterface', erc721MetaRes);

  console.log('supports IERC721:', supports721);
  console.log('supports IERC721Metadata:', supports721Metadata);

  const needsInterfaceInit = !supports721 || !supports721Metadata;
  if (toRemove.length === 0 && !needsInterfaceInit) {
    console.log('No on-chain changes required.');
    return;
  }

  let initAddress = ethers.ZeroAddress;
  let initCalldata = '0x';

  if (needsInterfaceInit) {
    const outArtifactPath = path.join(
      __dirname,
      '..',
      'out',
      'DiamondInit.sol',
      'DiamondInit.json'
    );
    const hhArtifactPath = path.join(
      __dirname,
      '..',
      'hh-artifacts',
      'contracts',
      'upgradeInitializers',
      'DiamondInit.sol',
      'DiamondInit.json'
    );
    const artifactPath = fs.existsSync(outArtifactPath) ? outArtifactPath : hhArtifactPath;
    const artifact = readJsonFile(artifactPath);
    const bytecode = artifact.bytecode && artifact.bytecode.object ? artifact.bytecode.object : artifact.bytecode;
    if (!bytecode) {
      throw new Error(`Unable to resolve bytecode from artifact: ${artifactPath}`);
    }

    const factory = new ethers.ContractFactory(artifact.abi, bytecode, wallet);
    if (argv.dryRun) {
      console.log('[dry-run] Would deploy DiamondInit and call init() via diamondCut _init');
      initAddress = ethers.ZeroAddress;
      initCalldata = '0x';
    } else {
      const initContract = await factory.deploy();
      console.log('Deploying DiamondInit tx:', initContract.deploymentTransaction().hash);
      await initContract.waitForDeployment();
      initAddress = await initContract.getAddress();
      console.log('DiamondInit deployed at:', initAddress);
      initCalldata = new ethers.Interface(artifact.abi).encodeFunctionData('init', []);
    }
  }

  const cuts = [];
  if (toRemove.length > 0) {
    cuts.push([ethers.ZeroAddress, 2, toRemove]);
  }

  const calldata = dcIface.encodeFunctionData('diamondCut', [cuts, initAddress, initCalldata]);

  if (argv.dryRun) {
    console.log('[dry-run] Prepared cuts:', JSON.stringify(cuts));
    if (needsInterfaceInit) {
      console.log('[dry-run] diamondCut calldata preview omitted because init address is deployed at runtime.');
    } else {
      console.log('[dry-run] init:', initAddress);
      console.log('[dry-run] calldata:', calldata);
    }
    return;
  }

  const tx = await wallet.sendTransaction({
    to: DIAMOND,
    data: calldata,
    gasLimit: 1_500_000
  });
  console.log('diamondCut tx:', tx.hash);
  const rcpt = await tx.wait();
  console.log('diamondCut confirmed in block:', rcpt.blockNumber);

  for (const sel of GHOST_SELECTORS) {
    const res = await provider.call({
      to: DIAMOND,
      data: loupeIface.encodeFunctionData('facetAddress', [sel])
    });
    const [currentFacet] = loupeIface.decodeFunctionResult('facetAddress', res);
    console.log(`post selector ${sel} -> ${currentFacet}`);
  }

  const post721Res = await provider.call({
    to: DIAMOND,
    data: loupeIface.encodeFunctionData('supportsInterface', [IERC721_ID])
  });
  const [postSupports721] = loupeIface.decodeFunctionResult('supportsInterface', post721Res);
  console.log('post supports IERC721:', postSupports721);

  const post721MetaRes = await provider.call({
    to: DIAMOND,
    data: loupeIface.encodeFunctionData('supportsInterface', [IERC721_METADATA_ID])
  });
  const [postSupports721Metadata] = loupeIface.decodeFunctionResult('supportsInterface', post721MetaRes);
  console.log('post supports IERC721Metadata:', postSupports721Metadata);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
