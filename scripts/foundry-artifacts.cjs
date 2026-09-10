const fs = require("node:fs");
const path = require("node:path");

function getArtifactIdentity(artifact) {
  const compilationTarget = artifact?.metadata?.settings?.compilationTarget;
  if (!compilationTarget || typeof compilationTarget !== "object" || Array.isArray(compilationTarget)) {
    return null;
  }

  const entries = Object.entries(compilationTarget);
  if (entries.length !== 1) return null;

  const [sourceName, contractName] = entries[0];
  if (!sourceName || !contractName || !Array.isArray(artifact.abi)) return null;

  return {sourceName, contractName};
}

function buildArtifactIndex(rootDir) {
  const artifactsRoot = path.join(rootDir, "out");
  const index = new Map();

  if (!fs.existsSync(artifactsRoot)) return index;

  function visit(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(entryPath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;

      try {
        const artifact = JSON.parse(fs.readFileSync(entryPath, "utf8"));
        const identity = getArtifactIdentity(artifact);
        if (!identity) continue;
        index.set(`${identity.sourceName}:${identity.contractName}`, entryPath);
      } catch {
        // Ignore non-artifact JSON files in the Foundry output directory.
      }
    }
  }

  visit(artifactsRoot);
  return index;
}

module.exports = {buildArtifactIndex, getArtifactIdentity};
