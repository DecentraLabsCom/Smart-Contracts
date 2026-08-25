const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const rootDir = path.resolve(__dirname, "..");

function selectorSignaturesFor(fixture, helperName) {
  const declaration = `function _${helperName}Selectors`;
  const start = fixture.indexOf(declaration);
  assert.notEqual(start, -1, `fixture is missing ${declaration}`);
  const nextFunction = fixture.indexOf("\n    function ", start + declaration.length);
  const source = fixture.slice(start, nextFunction === -1 ? undefined : nextFunction);
  return [...source.matchAll(/_selector\(\s*"([^"]+)"\s*\)/g)]
    .map(([, signature]) => signature)
    .sort();
}

test("the full Diamond fixture mirrors the production selector manifest", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(rootDir, "selectors", "diamond.json"), "utf8"));
  const fixture = fs.readFileSync(path.join(__dirname, "FullDiamondFixture.sol"), "utf8");
  const manifestSelectors = manifest.facets.flatMap(({functions}) => functions).sort();
  const fixtureSelectors = [...fixture.matchAll(/_selector\(\s*"([^"]+)"\s*\)/g)]
    .map(([, signature]) => signature)
    .sort();

  assert.deepEqual(fixtureSelectors, manifestSelectors);

  for (const {name} of manifest.facets) {
    assert.match(fixture, new RegExp(`new ${name}\\s*\\(`));
  }

  for (const {name, functions} of manifest.facets) {
    const helperName = name === "InitFacet" || name === "DiamondCutFacet"
      ? name.replace("Facet", "")
      : name.replace(/Facet$/, "");
    assert.deepEqual(
      selectorSignaturesFor(fixture, helperName),
      [...functions].sort(),
      `${name} selector list differs from the production manifest`,
    );
  }
});
