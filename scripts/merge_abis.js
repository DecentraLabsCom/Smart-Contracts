import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);
const {
  buildPublicAbi,
  loadSelectorManifest,
  validateSelectorManifest,
} = require('./selector-manifest.cjs');
const ROOT_DIR = path.join(__dirname, '..');
const OUT_FILE = path.join(__dirname, '..', 'abi', 'Diamond.json');

function main() {
  const manifest = loadSelectorManifest(ROOT_DIR);
  const validation = validateSelectorManifest(ROOT_DIR, manifest);
  if (validation.errors.length) throw new Error(validation.errors.join('\n'));
  const abi = buildPublicAbi(ROOT_DIR, manifest);
  fs.writeFileSync(OUT_FILE, `${JSON.stringify(abi, null, 2)}\n`);
  console.log(`Wrote manifest-derived ABI to ${OUT_FILE} (${validation.allowedSelectors.size} functions)`);
}

main();
