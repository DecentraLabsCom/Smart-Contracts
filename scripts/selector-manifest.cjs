#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {ethers} = require("ethers");

function canonicalType(input) {
  if (!input.type.startsWith("tuple")) return input.type;
  const suffix = input.type.slice("tuple".length);
  return `(${(input.components || []).map(canonicalType).join(",")})${suffix}`;
}

function signatureFor(entry) {
  return `${entry.name}(${(entry.inputs || []).map(canonicalType).join(",")})`;
}

function artifactPath(rootDir, target) {
  const separator = target.lastIndexOf(":");
  if (separator < 0) throw new Error(`Invalid target: ${target}`);
  const source = target.slice(0, separator);
  const contractName = target.slice(separator + 1);
  return path.join(rootDir, "out", path.basename(source), `${contractName}.json`);
}

function readArtifact(rootDir, facet) {
  const file = artifactPath(rootDir, facet.target);
  if (!fs.existsSync(file)) throw new Error(`Missing artifact for ${facet.name}: ${file}`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function loadSelectorManifest(rootDir) {
  return JSON.parse(fs.readFileSync(path.join(rootDir, "selectors", "diamond.json"), "utf8"));
}

function validateSelectorManifest(rootDir, manifest) {
  const errors = [];
  const allowedSelectors = new Map();
  const allowedFunctions = new Set();
  const forbiddenFunctions = new Set(manifest.forbiddenFunctions || []);

  for (const facet of manifest.facets || []) {
    let artifact;
    try {
      artifact = readArtifact(rootDir, facet);
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    const artifactFunctions = new Set(
      (artifact.abi || []).filter((entry) => entry.type === "function").map(signatureFor),
    );
    for (const signature of facet.functions || []) {
      if (!artifactFunctions.has(signature)) errors.push(`${facet.name} does not expose ${signature}`);
      if (allowedFunctions.has(signature)) errors.push(`${signature} is assigned more than once`);
      if (forbiddenFunctions.has(signature)) errors.push(`${signature} is both allowed and forbidden`);
      allowedFunctions.add(signature);

      const selector = ethers.id(signature).slice(0, 10).toLowerCase();
      const previous = allowedSelectors.get(selector);
      if (previous && previous !== signature) errors.push(`${selector} collides: ${previous} / ${signature}`);
      allowedSelectors.set(selector, signature);
    }
  }

  for (const facet of manifest.facets || []) {
    let artifact;
    try {
      artifact = readArtifact(rootDir, facet);
    } catch {
      continue;
    }
    for (const entry of (artifact.abi || []).filter((item) => item.type === "function")) {
      const signature = signatureFor(entry);
      if (forbiddenFunctions.has(signature)) {
        errors.push(`${facet.name} still compiles forbidden function ${signature}`);
      } else if (!allowedFunctions.has(signature)) {
        errors.push(`${facet.name} exposes unclassified function ${signature}`);
      }
    }
  }

  for (const signature of manifest.internalRoutingFunctions || []) {
    if (!allowedFunctions.has(signature)) errors.push(`Internal routing function is not routed: ${signature}`);
  }

  return {errors: [...new Set(errors)].sort(), allowedSelectors, allowedFunctions};
}

function buildPublicAbi(rootDir, manifest) {
  const entries = new Map();
  for (const facet of manifest.facets) {
    const artifact = readArtifact(rootDir, facet);
    const facetFunctions = new Set(facet.functions);
    for (const entry of artifact.abi || []) {
      if (entry.type === "constructor") continue;
      if (entry.type === "function" && !facetFunctions.has(signatureFor(entry))) continue;
      const key = entry.type === "function" || entry.type === "error" || entry.type === "event"
        ? `${entry.type}:${signatureFor(entry)}`
        : `${entry.type}:${JSON.stringify(entry)}`;
      if (!entries.has(key)) entries.set(key, entry);
    }
  }
  return [...entries.values()];
}

function main() {
  const rootDir = path.resolve(__dirname, "..");
  const manifest = loadSelectorManifest(rootDir);
  const result = validateSelectorManifest(rootDir, manifest);
  if (result.errors.length > 0) {
    for (const error of result.errors) console.error(`- ${error}`);
    process.exitCode = 1;
    return;
  }
  const targetIndex = process.argv.indexOf("--target");
  if (targetIndex >= 0) {
    const target = process.argv[targetIndex + 1];
    const facet = manifest.facets.find((entry) => entry.target === target);
    if (!facet) throw new Error(`Target is not declared in selector manifest: ${target}`);
    console.log(JSON.stringify(facet.functions.map((signature) => ({
      signature,
      selector: ethers.id(signature).slice(0, 10).toLowerCase(),
    }))));
    return;
  }
  console.log(`Selector manifest valid: ${result.allowedSelectors.size} selectors`);
}

if (require.main === module) main();

module.exports = {
  artifactPath,
  buildPublicAbi,
  canonicalType,
  loadSelectorManifest,
  signatureFor,
  validateSelectorManifest,
};
