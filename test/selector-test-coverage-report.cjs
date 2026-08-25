const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const manifestPath = path.join(rootDir, "selectors", "diamond.json");
const testDir = path.join(rootDir, "test");

function collectSolidityTests(directory) {
  return fs.readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return collectSolidityTests(entryPath);
    if (!entry.isFile() || !entry.name.endsWith(".t.sol")) return [];
    if (entry.name === "FullDiamondFixture.sol") return [];
    return [entryPath];
  });
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function buildCoverageRows(manifest, testSource) {
  return manifest.facets.flatMap(({name: facet, functions}) => functions.map((signature) => {
    const functionName = signature.slice(0, signature.indexOf("("));
    const behaviorTestReference = new RegExp(`\\b${escapeRegExp(functionName)}\\b`).test(testSource);
    return {
      facet,
      signature,
      functionName,
      proxyRoutingSmoke: true,
      behaviorTestReference,
      status: behaviorTestReference ? "behavior-reference" : "proxy-smoke-only",
    };
  }));
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const testSource = collectSolidityTests(testDir)
  .map((filePath) => fs.readFileSync(filePath, "utf8"))
  .join("\n");
const rows = buildCoverageRows(manifest, testSource);
const behaviorReferences = rows.filter(({behaviorTestReference}) => behaviorTestReference);
const smokeOnly = rows.filter(({behaviorTestReference}) => !behaviorTestReference);

if (process.argv.includes("--json")) {
  process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`);
} else {
  console.log(`Public selectors: ${rows.length}`);
  console.log(`Behavior-test references: ${behaviorReferences.length}`);
  console.log(`Proxy-routing smoke coverage: ${rows.filter(({proxyRoutingSmoke}) => proxyRoutingSmoke).length}`);
  console.log(`Proxy-smoke-only selectors: ${smokeOnly.length}`);

  for (const row of smokeOnly) {
    console.log(`${row.facet}: ${row.signature}`);
  }
}
