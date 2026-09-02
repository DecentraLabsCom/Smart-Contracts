const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const rootDir = path.resolve(__dirname, "..");

test("repository documentation has no broken links or executable references", () => {
  const {validateDocumentation, validatePackageScriptTargets} = require("../scripts/verify-documentation.cjs");

  assert.deepEqual(validateDocumentation(rootDir), []);
  assert.deepEqual(validatePackageScriptTargets(rootDir), []);
});

test("documentation validation catches an unknown command and link", () => {
  const {validateDocumentationText} = require("../scripts/verify-documentation.cjs");
  const errors = validateDocumentationText(
    rootDir,
    "docs/example.md",
    "[missing](not-present.md)\n`npm run command-that-does-not-exist`",
  );

  assert.ok(errors.some((error) => error.includes("not-present.md")));
  assert.ok(errors.some((error) => error.includes("command-that-does-not-exist")));
});

test("facet reference covers the deployed selector manifest", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(rootDir, "selectors", "diamond.json"), "utf8"));
  const reference = fs.readFileSync(path.join(rootDir, "docs", "reference", "facets.md"), "utf8");

  for (const {name} of manifest.facets) assert.match(reference, new RegExp(`\\b${name}\\b`));
  assert.match(reference, /201/);
  assert.match(reference, /EIP-712/);
});
