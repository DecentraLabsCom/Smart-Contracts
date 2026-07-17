#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const source = path.join(rootDir, "abi", "Diamond.json");
const targets = [
  path.resolve(rootDir, "..", "Marketplace", "src", "contracts", "diamondAbi.json"),
  path.resolve(rootDir, "..", "Lab Gateway", "blockchain-services", "abi", "Diamond.json"),
];
const checkOnly = process.argv.includes("--check-consumers");

if (!fs.existsSync(source)) throw new Error(`Missing canonical ABI: ${source}`);
const canonical = fs.readFileSync(source, "utf8");
const errors = [];

for (const target of targets) {
  if (checkOnly) {
    if (!fs.existsSync(target)) {
      errors.push(`Missing consumer ABI: ${target}`);
      continue;
    }
    if (fs.readFileSync(target, "utf8") !== canonical) errors.push(`Consumer ABI is stale: ${target}`);
    continue;
  }

  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.writeFileSync(target, canonical);
  console.log(`Synchronized ${target}`);
}

if (errors.length) {
  for (const error of errors) console.error(error);
  process.exitCode = 1;
}
