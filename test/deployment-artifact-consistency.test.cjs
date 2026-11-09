const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const {spawnSync} = require("node:child_process");
const test = require("node:test");

const {
  validateDeploymentArtifactConsistency,
} = require("../scripts/verify-repo-consistency.cjs");

const rootDir = path.resolve(__dirname, "..");
const latest = JSON.parse(fs.readFileSync(path.join(rootDir, "deployments", "sepolia-latest.json"), "utf8"));
const backendManifestPath = path.join(
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
const backend = fs.existsSync(backendManifestPath)
  ? JSON.parse(fs.readFileSync(backendManifestPath, "utf8"))
  : null;

test("versioned Sepolia artifacts describe the same Diamond and facet addresses", {skip: !backend}, () => {
  assert.deepEqual(validateDeploymentArtifactConsistency(latest, backend), []);
});

test("deployment consistency rejects a stale backend facet address", {skip: !backend}, () => {
  const staleBackend = structuredClone(backend);
  staleBackend.facets.find(({name}) => name === "ServiceCreditFacet").address = "0x0000000000000000000000000000000000000001";

  const errors = validateDeploymentArtifactConsistency(latest, staleBackend);

  assert.ok(errors.some((error) => error.includes("ServiceCreditFacet")));
});

test("consumer artifact checks tolerate checkout line endings and reject content drift", () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "smart-contracts-consumers-"));
  try {
    const fixtureRoot = path.join(workspace, "Smart-Contracts");
    const fixtureScript = path.join(fixtureRoot, "scripts", "sync-consumer-abis.cjs");
    const canonical = '{\n  "version": 1\n}\n';
    const artifacts = [
      ["Smart-Contracts/abi/Diamond.json", canonical],
      ["Smart-Contracts/selectors/diamond.json", canonical],
      ["Marketplace/src/contracts/diamondAbi.json", canonical.replace(/\n/g, "\r\n")],
      ["Lab Gateway/blockchain-services/abi/Diamond.json", canonical],
      ["Lab Gateway/blockchain-services/src/main/resources/contract/selector-manifest.json", canonical.replace(/\n/g, "\r\n")],
    ];
    for (const [relativePath, content] of artifacts) {
      const destination = path.join(workspace, relativePath);
      fs.mkdirSync(path.dirname(destination), {recursive: true});
      fs.writeFileSync(destination, content);
    }
    fs.mkdirSync(path.dirname(fixtureScript), {recursive: true});
    fs.copyFileSync(path.join(rootDir, "scripts", "sync-consumer-abis.cjs"), fixtureScript);
    const check = () => spawnSync(process.execPath, [fixtureScript, "--check-consumers"], {encoding: "utf8"});

    const equivalent = check();
    assert.equal(equivalent.status, 0, equivalent.stderr);
    const marketplaceAbi = path.join(workspace, "Marketplace/src/contracts/diamondAbi.json");
    assert.equal(fs.readFileSync(marketplaceAbi, "utf8"), canonical.replace(/\n/g, "\r\n"));

    fs.writeFileSync(marketplaceAbi, canonical.replace("1", "2"));
    const stale = check();
    assert.equal(stale.status, 1);
    assert.match(stale.stderr, /Consumer contract artifact is stale:/);
  } finally {
    fs.rmSync(workspace, {recursive: true, force: true});
  }
});
