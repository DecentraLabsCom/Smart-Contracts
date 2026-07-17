#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {loadSelectorManifest, validateSelectorManifest} = require("./selector-manifest.cjs");

const rootDir = path.resolve(__dirname, "..");
const errors = [];
const read = (relativePath) => fs.readFileSync(path.join(rootDir, relativePath), "utf8").replace(/^\uFEFF/, "");

if (!fs.existsSync(path.join(rootDir, "scripts", "deploy_credits.ps1"))) {
  errors.push("README/deployment docs reference scripts/deploy_credits.ps1, but the file is missing");
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

if (errors.length) {
  for (const error of [...new Set(errors)].sort()) console.error(`- ${error}`);
  process.exitCode = 1;
} else {
  console.log("Repository consistency checks passed");
}
