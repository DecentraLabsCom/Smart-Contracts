const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "selectors", "diamond.json"), "utf8"));

test("reservation intent selectors are split into deployable facets", () => {
  const byTarget = new Map(manifest.facets.map((facet) => [facet.target, facet.functions]));
  assert.deepEqual(
    byTarget.get("contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet"),
    [
      "institutionalDirectBookingWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))",
      "institutionalReservationRequestWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))",
    ],
  );
  assert.deepEqual(
    byTarget.get(
      "contracts/facets/reservation/ReservationIntentCancellationFacet.sol:ReservationIntentCancellationFacet",
    ),
    [
      "cancelInstitutionalBookingWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))",
      "cancelInstitutionalReservationRequestWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))",
    ],
  );
});
