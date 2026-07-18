const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");

const {
  buildPublicAbi,
  canonicalType,
  loadSelectorManifest,
  validateSelectorManifest,
} = require("../scripts/selector-manifest.cjs");

const rootDir = path.resolve(__dirname, "..");

test("the credit-ledger selector manifest is complete and collision-free", () => {
  const manifest = loadSelectorManifest(rootDir);
  const result = validateSelectorManifest(rootDir, manifest);
  const expectedSelectorCount = manifest.facets.flatMap((facet) => facet.functions).length;

  assert.deepEqual(result.errors, []);
  assert.equal(result.allowedSelectors.size, expectedSelectorCount);
});

test("unsupported wallet, credit, migration, and generic role functions are forbidden", () => {
  const manifest = loadSelectorManifest(rootDir);
  const allowed = new Set(manifest.facets.flatMap((facet) => facet.functions));
  const expectedForbidden = [
    "reservationRequest(uint256,uint32,uint32)",
    "confirmReservationRequest(bytes32)",
    "cancelReservationRequest(bytes32)",
    "cancelBooking(bytes32)",
    "issueServiceCredits(address,uint256,bytes32)",
    "adjustServiceCredits(address,int256,bytes32)",
    "getServiceCreditBalance(address)",
    "getMyServiceCreditBalance()",
    "grantRole(bytes32,address)",
    "revokeRole(bytes32,address)",
    "renounceRole(bytes32,address)",
    "getLabProviders()",
    "setLabOwnerPucHash(uint256,bytes32)",
  ];

  for (const signature of expectedForbidden) {
    assert.ok(manifest.forbiddenFunctions.includes(signature), `${signature} must be explicitly forbidden`);
    assert.ok(!allowed.has(signature), `${signature} must not be routed`);
  }
});

test("the generated public ABI contains only allowlisted functions", () => {
  const manifest = loadSelectorManifest(rootDir);
  const abi = buildPublicAbi(rootDir, manifest);
  const functions = new Set(
    abi
      .filter((entry) => entry.type === "function")
      .map((entry) => `${entry.name}(${(entry.inputs || []).map(canonicalType).join(",")})`),
  );
  const allowed = new Set(manifest.facets.flatMap((facet) => facet.functions));

  assert.deepEqual(functions, allowed);
});
