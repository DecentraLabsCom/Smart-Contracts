const assert = require("node:assert/strict");
const test = require("node:test");

const {
  buildFacetAddressMap,
  optionValue,
} = require("../scripts/verify-all-facets-selectors.cjs");

test("optionValue does not consume the next option when an option is omitted", () => {
  assert.equal(optionValue(["--diamond", "0x1234"], "--rpc", "from-env"), "from-env");
  assert.equal(optionValue(["--rpc", "https://rpc.example", "--diamond", "0x1234"], "--rpc", "from-env"), "https://rpc.example");
});

test("optionValue rejects an option without a value", () => {
  assert.throws(() => optionValue(["--rpc", "--diamond", "0x1234"], "--rpc", "from-env"), /requires a value/);
});

test("selector verification resolves facet targets from the current deployment snapshot", () => {
  const target = "contracts/facets/ServiceCreditFacet.sol:ServiceCreditFacet";
  const map = buildFacetAddressMap(
    {contracts: {}, facets: {ServiceCreditFacet: "0x0000000000000000000000000000000000000002"}},
    [{name: "ServiceCreditFacet", target}],
  );

  assert.equal(map[target], "0x0000000000000000000000000000000000000002");
});
