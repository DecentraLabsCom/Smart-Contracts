const assert = require("node:assert/strict");
const test = require("node:test");
const {id, ZeroAddress} = require("ethers");

const {
  DIRECT_RESERVATION_SIGNATURE,
  DIRECT_RESERVATION_SELECTOR,
  buildRemovalCut,
} = require("../scripts/remove-institutional-reservation-selector.cjs");

test("the targeted reservation migration removes only the retired direct selector", () => {
  assert.equal(
    DIRECT_RESERVATION_SELECTOR,
    id(DIRECT_RESERVATION_SIGNATURE).slice(0, 10).toLowerCase(),
  );

  assert.deepEqual(buildRemovalCut(), [{
    facetAddress: ZeroAddress,
    action: 2,
    functionSelectors: [DIRECT_RESERVATION_SELECTOR],
  }]);
});
