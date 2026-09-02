const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const rootDir = path.resolve(__dirname, "..");
const script = fs.readFileSync(path.join(rootDir, "scripts", "deploy_credits.ps1"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(rootDir, "selectors", "diamond.json"), "utf8"));

function blockBetween(startMarker, endMarker) {
  const start = script.indexOf(startMarker);
  const end = script.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `${startMarker} must exist`);
  assert.notEqual(end, -1, `${endMarker} must exist after ${startMarker}`);
  return script.slice(start, end);
}

test("deployment state-changing calls fail closed instead of warning and continuing", () => {
  const diamondCutBatch = blockBetween("function DiamondCutBatch", "function DiamondCut {");
  const sendCall = blockBetween("function Send-Call", 'Write-Host "Initializing Diamond facets..."');

  assert.match(diamondCutBatch, /\$LASTEXITCODE/);
  assert.match(diamondCutBatch, /throw .*diamondCut/i);
  assert.match(sendCall, /throw .*initialization/i);
  assert.doesNotMatch(sendCall, /Write-Warning .*SKIPPING/i);
  assert.match(sendCall, /throw .*failed/i);
});

test("deployment artifacts serialize every facet in the selector manifest", () => {
  const artifactSerializer = blockBetween("$deployment = [ordered]@{", "$deployment | ConvertTo-Json");

  for (const {name} of manifest.facets) {
    assert.match(
      artifactSerializer,
      new RegExp(`^\\s+${name}\\s*=`, "m"),
      `${name} must be present in the deployment artifact serializer`,
    );
  }
});
