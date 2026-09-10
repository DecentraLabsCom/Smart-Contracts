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
