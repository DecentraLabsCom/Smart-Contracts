#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const rootDir = path.resolve(__dirname, "..");
const errors = [];
const read = (relativePath) => fs.readFileSync(path.join(rootDir, relativePath), "utf8").replace(/^\uFEFF/, "");

function validateDeploymentArtifactConsistency(latest, backend) {
  const consistencyErrors = [];
  const normalizeAddress = (value) => String(value || "").toLowerCase();
  const latestDiamond = latest?.contracts?.Diamond;
  const backendDiamond = backend?.diamondAddress;

  if (latest?.network !== backend?.network) {
    consistencyErrors.push(`Deployment network differs: latest=${latest?.network}, backend=${backend?.network}`);
  }
  if (Number(latest?.chainId) !== Number(backend?.chainId)) {
    consistencyErrors.push(`Deployment chain ID differs: latest=${latest?.chainId}, backend=${backend?.chainId}`);
  }
  if (normalizeAddress(latestDiamond) !== normalizeAddress(backendDiamond)) {
    consistencyErrors.push(`Diamond address differs: latest=${latestDiamond}, backend=${backendDiamond}`);
  }

  const latestInit = latest?.contracts?.DiamondInit;
  const backendInit = backend?.criticalAddresses?.DiamondInit;
  if (normalizeAddress(latestInit) !== normalizeAddress(backendInit)) {
    consistencyErrors.push(`DiamondInit address differs: latest=${latestInit}, backend=${backendInit}`);
  }

  const latestFacetAddresses = {
    ...(latest?.facets || {}),
    ...(latest?.contracts || {}),
  };
  for (const facet of backend?.facets || []) {
    const latestAddress = latestFacetAddresses[facet.name];
    if (!latestAddress) {
      consistencyErrors.push(`Backend deployment manifest facet is absent from sepolia-latest.json: ${facet.name}`);
    } else if (normalizeAddress(latestAddress) !== normalizeAddress(facet.address)) {
      consistencyErrors.push(`Facet address differs for ${facet.name}: latest=${latestAddress}, backend=${facet.address}`);
    }
  }

  return consistencyErrors;
}

if (!fs.existsSync(path.join(rootDir, "scripts", "deploy_credits.ps1"))) {
  errors.push("README/deployment docs reference scripts/deploy_credits.ps1, but the file is missing");
} else if (!read("scripts/deploy_credits.ps1").includes('"--optimizer-runs", "1"')) {
  errors.push("scripts/deploy_credits.ps1 must pin optimizer-runs for reproducible EIP-170-safe deployments");
}

const storageSource = read("contracts/libraries/LibAppStorage.sol");
if (!storageSource.includes("DEFAULT_SPENDING_PERIOD = 120 days")) {
  errors.push("LibAppStorage.DEFAULT_SPENDING_PERIOD is not the documented 120-day default");
}
for (const file of [
  "contracts/libraries/LibAppStorage.sol",
  "contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol",
]) {
  if (read(file).includes("default: 30 days")) errors.push(`${file} contains a stale 30-day default comment`);
}

const packageJson = JSON.parse(read("package.json"));
const packageLock = JSON.parse(read("package-lock.json"));
const rootLock = packageLock.packages[""];
for (const section of ["dependencies", "devDependencies"]) {
  for (const [name, version] of Object.entries(packageJson[section] || {})) {
    if (rootLock?.[section]?.[name] !== version) {
      errors.push(`package-lock root constraint differs for ${name}`);
    }
  }
}

const manifest = loadSelectorManifest(rootDir);
const validation = validateSelectorManifest(rootDir, manifest);
errors.push(...validation.errors);

const resume = JSON.parse(read("deployments/sepolia-resume.json"));
const manifestTargets = new Set((manifest.facets || []).map((facet) => facet.target));
for (const target of Object.keys(resume.facets || {})) {
  if (!manifestTargets.has(target)) errors.push(`Deployment resume contains stale facet not in selector manifest: ${target}`);
}

const backendManifestPath = path.resolve(
  rootDir,
  "..",
  "Lab Gateway",
  "blockchain-services",
  "src",
  "main",
  "resources",
  "contract",
  "deployment-manifest.json",
);
if (fs.existsSync(backendManifestPath)) {
  const latest = JSON.parse(read("deployments/sepolia-latest.json"));
  const backend = JSON.parse(fs.readFileSync(backendManifestPath, "utf8"));
  errors.push(...validateDeploymentArtifactConsistency(latest, backend));
}

if (errors.length) {
  for (const error of [...new Set(errors)].sort()) console.error(`- ${error}`);
  process.exitCode = 1;
} else {
  console.log("Repository consistency checks passed");
}

module.exports = {validateDeploymentArtifactConsistency};
