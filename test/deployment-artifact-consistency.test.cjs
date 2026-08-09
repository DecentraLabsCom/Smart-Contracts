const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  validateDeploymentArtifactConsistency,
} = require("../scripts/verify-repo-consistency.cjs");

const rootDir = path.resolve(__dirname, "..");
const latest = JSON.parse(fs.readFileSync(path.join(rootDir, "deployments", "sepolia-latest.json"), "utf8"));
const backend = JSON.parse(fs.readFileSync(
  path.join(rootDir, "..", "Lab Gateway", "blockchain-services", "src", "main", "resources", "contract", "deployment-manifest.json"),
  "utf8",
));

test("versioned Sepolia artifacts describe the same Diamond and facet addresses", () => {
  assert.deepEqual(validateDeploymentArtifactConsistency(latest, backend), []);
});

test("deployment consistency rejects a stale backend facet address", () => {
  const staleBackend = structuredClone(backend);
  staleBackend.facets.find(({name}) => name === "ServiceCreditFacet").address = "0x0000000000000000000000000000000000000001";

  const errors = validateDeploymentArtifactConsistency(latest, staleBackend);

  assert.ok(errors.some((error) => error.includes("ServiceCreditFacet")));
});
