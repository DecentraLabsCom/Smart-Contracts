const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  buildPublicAbi,
  canonicalType,
  loadSelectorManifest,
  signatureFor,
  validateSelectorManifest,
} = require("../scripts/selector-manifest.cjs");
const {id} = require("ethers");

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
    "listToken(uint256)",
    "unlistToken(uint256)",
    "issueServiceCredits(address,uint256,bytes32)",
    "adjustServiceCredits(address,int256,bytes32)",
    "getServiceCreditBalance(address)",
    "getMyServiceCreditBalance()",
    "grantRole(bytes32,address)",
    "revokeRole(bytes32,address)",
    "renounceRole(bytes32,address)",
    "grantInstitutionRole(address,string)",
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

test("expected, facet-artifact, and Diamond-facing selectors agree", () => {
  const manifest = loadSelectorManifest(rootDir);
  const result = validateSelectorManifest(rootDir, manifest);
  const publicBySignature = new Map(
    buildPublicAbi(rootDir, manifest)
      .filter((entry) => entry.type === "function")
      .map((entry) => [signatureFor(entry), entry]),
  );
  const diamondAbi = JSON.parse(fs.readFileSync(path.join(rootDir, "abi", "Diamond.json"), "utf8"));
  const diamondBySignature = new Map(
    diamondAbi
      .filter((entry) => entry.type === "function")
      .map((entry) => [signatureFor(entry), entry]),
  );

  for (const facet of manifest.facets) {
    for (const signature of facet.functions) {
      const publicEntry = publicBySignature.get(signature);
      const diamondEntry = diamondBySignature.get(signature);
      assert.ok(publicEntry, `${signature} must be present in the generated Diamond ABI`);
      assert.ok(diamondEntry, `${signature} must be present in the checked-in Diamond ABI`);
      const selector = id(signature).slice(0, 10).toLowerCase();
      assert.equal(id(signatureFor(publicEntry)).slice(0, 10).toLowerCase(), selector);
      assert.equal(id(signatureFor(diamondEntry)).slice(0, 10).toLowerCase(), selector);
      assert.equal(result.allowedSelectors.get(selector), signature);
    }
  }
});
