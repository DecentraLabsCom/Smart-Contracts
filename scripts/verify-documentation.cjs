#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

function markdownFiles(rootDir) {
  const files = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(entryPath);
      else if (entry.isFile() && entry.name.endsWith(".md")) files.push(entryPath);
    }
  };

  for (const relativePath of ["README.md", "SUMMARY.md", "docs"]) {
    const target = path.join(rootDir, relativePath);
    if (fs.existsSync(target)) {
      if (fs.statSync(target).isDirectory()) visit(target);
      else files.push(target);
    }
  }
  return files.sort();
}

function packageScripts(rootDir) {
  return Object.keys(JSON.parse(fs.readFileSync(path.join(rootDir, "package.json"), "utf8")).scripts || {});
}

function validatePackageScriptTargets(rootDir) {
  const errors = [];
  const scripts = JSON.parse(fs.readFileSync(path.join(rootDir, "package.json"), "utf8")).scripts || {};
  for (const [name, command] of Object.entries(scripts)) {
    for (const match of command.matchAll(/(?:node\s+)?(scripts\/[A-Za-z0-9_.-]+\.(?:cjs|js|mjs|ps1))/g)) {
      if (!fs.existsSync(path.join(rootDir, match[1]))) {
        errors.push(`package.json: npm script ${name} references missing ${match[1]}`);
      }
    }
  }
  return errors;
}

function relativeMarkdownLinks(text) {
  const links = [];
  const pattern = /!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)/g;
  for (const match of text.matchAll(pattern)) {
    const target = match[1];
    if (!target.startsWith("#") && !/^[a-z][a-z\d+.-]*:/i.test(target) && !target.startsWith("//")) {
      links.push(target.split("#", 1)[0]);
    }
  }
  return links.filter(Boolean);
}

function documentedReferences(text) {
  const references = [];
  for (const match of text.matchAll(/npm run\s+([A-Za-z0-9:_-]+)/g)) {
    references.push({kind: "npm script", value: match[1]});
  }
  for (const match of text.matchAll(/(?:node\s+)?(scripts\/[A-Za-z0-9_.-]+\.(?:cjs|js|mjs|ps1))/g)) {
    references.push({kind: "script", value: match[1]});
  }
  for (const match of text.matchAll(/forge\s+test\s+[^`\n]*?--match-path\s+(test\/[A-Za-z0-9_.-]+)/g)) {
    references.push({kind: "test path", value: match[1]});
  }
  return references;
}

function validateDocumentationText(rootDir, relativeFile, text) {
  const errors = [];
  const packageScriptNames = new Set(packageScripts(rootDir));
  const sourcePath = path.join(rootDir, relativeFile);

  for (const target of relativeMarkdownLinks(text)) {
    const resolved = path.resolve(path.dirname(sourcePath), target);
    if (!fs.existsSync(resolved)) errors.push(`${relativeFile}: broken relative link ${target}`);
  }

  for (const reference of documentedReferences(text)) {
    if (reference.kind === "npm script") {
      if (!packageScriptNames.has(reference.value)) {
        errors.push(`${relativeFile}: unknown npm script ${reference.value}`);
      }
      continue;
    }
    if (!fs.existsSync(path.join(rootDir, reference.value))) {
      errors.push(`${relativeFile}: missing ${reference.kind} ${reference.value}`);
    }
  }
  return errors;
}

function validateDocumentation(rootDir) {
  return [
    ...validatePackageScriptTargets(rootDir),
    ...markdownFiles(rootDir).flatMap((file) => {
      const relativeFile = path.relative(rootDir, file).replaceAll(path.sep, "/");
      return validateDocumentationText(rootDir, relativeFile, fs.readFileSync(file, "utf8"));
    }),
  ];
}

if (require.main === module) {
  const rootDir = path.resolve(__dirname, "..");
  const errors = [...new Set(validateDocumentation(rootDir))].sort();
  if (errors.length) {
    for (const error of errors) console.error(`- ${error}`);
    process.exitCode = 1;
  } else {
    console.log(`Documentation checks passed (${markdownFiles(rootDir).length} Markdown files)`);
  }
}

module.exports = {
  documentedReferences,
  markdownFiles,
  relativeMarkdownLinks,
  validatePackageScriptTargets,
  validateDocumentation,
  validateDocumentationText,
};
