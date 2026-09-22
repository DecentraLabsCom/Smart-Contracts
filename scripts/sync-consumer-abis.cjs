#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const synchronizedFiles = [
  {
    source: path.join(rootDir, "abi", "Diamond.json"),
    targets: [
      path.resolve(rootDir, "..", "Marketplace", "src", "contracts", "diamondAbi.json"),
      path.resolve(rootDir, "..", "Lab Gateway", "blockchain-services", "abi", "Diamond.json"),
    ],
  },
  {
    source: path.join(rootDir, "selectors", "diamond.json"),
    targets: [
      path.resolve(
        rootDir,
        "..",
        "Lab Gateway",
        "blockchain-services",
        "src",
        "main",
        "resources",
        "contract",
        "selector-manifest.json",
      ),
    ],
  },
];
const checkOnly = process.argv.includes("--check-consumers");

const errors = [];

for (const {source, targets} of synchronizedFiles) {
  if (!fs.existsSync(source)) throw new Error(`Missing canonical contract artifact: ${source}`);
  const canonical = fs.readFileSync(source, "utf8");

  for (const target of targets) {
    if (checkOnly) {
      if (!fs.existsSync(target)) {
        errors.push(`Missing consumer contract artifact: ${target}`);
        continue;
      }
      if (fs.readFileSync(target, "utf8") !== canonical) {
        errors.push(`Consumer contract artifact is stale: ${target}`);
      }
      continue;
    }

    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, canonical);
    console.log(`Synchronized ${target}`);
  }
}

if (errors.length) {
  for (const error of errors) console.error(error);
  process.exitCode = 1;
}
