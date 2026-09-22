const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  buildArtifactIndex,
  getArtifactIdentity,
} = require("../scripts/foundry-artifacts.cjs");

test("reads a Foundry artifact compilation target", () => {
  const artifact = {
    abi: [],
    metadata: {
      settings: {
        compilationTarget: {
          "contracts/facets/ExampleFacet.sol": "ExampleFacet",
        },
      },
    },
  };

  assert.deepEqual(getArtifactIdentity(artifact), {
    sourceName: "contracts/facets/ExampleFacet.sol",
    contractName: "ExampleFacet",
  });
});

test("indexes Foundry artifacts by Solidity target", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "smart-contracts-artifacts-"));
  try {
    const artifactPath = path.join(rootDir, "out", "ExampleFacet.sol", "ExampleFacet.json");
    fs.mkdirSync(path.dirname(artifactPath), {recursive: true});
    fs.writeFileSync(artifactPath, JSON.stringify({
      abi: [],
      metadata: {
        settings: {
          compilationTarget: {
            "contracts/facets/ExampleFacet.sol": "ExampleFacet",
          },
        },
      },
    }));

    const index = buildArtifactIndex(rootDir);

    assert.equal(
      index.get("contracts/facets/ExampleFacet.sol:ExampleFacet"),
      artifactPath,
    );
  } finally {
    fs.rmSync(rootDir, {recursive: true, force: true});
  }
});

test("production facets fit the EIP-170 runtime bytecode limit", () => {
  const rootDir = path.resolve(__dirname, "..");
  const manifest = JSON.parse(fs.readFileSync(path.join(rootDir, "selectors", "diamond.json"), "utf8"));
  const artifacts = buildArtifactIndex(rootDir);

  for (const facet of manifest.facets) {
    const artifactPath = artifacts.get(facet.target);
    assert.ok(artifactPath, `Missing Foundry artifact for ${facet.target}`);
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const runtimeBytecode = artifact.deployedBytecode?.object ?? "";
    const runtimeSize = runtimeBytecode.replace(/^0x/, "").length / 2;
    assert.ok(runtimeSize <= 24_576, `${facet.name} runtime is ${runtimeSize} bytes (EIP-170 max: 24576)`);
  }
});
