#!/usr/bin/env node
// extract_sources.js
// Reads <input-file> and writes each source file into <output-dir>
//
// Usage: node extract_sources.js [--input <file>] [--output <dir>]
//   --input   Path to Standard JSON input file (default: input.json)
//   --output  Output directory name or path      (default: parsed_src_<timestamp>)

const fs = require('fs');
const path = require('path');

// Parse CLI arguments
const args = process.argv.slice(2);
function getArg(flag) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : null;
}

const inputFile = getArg('--input') || 'input.json';
const timestamp = Math.floor(Date.now() / 1000);
const outputArg = getArg('--output') || `parsed_src_${timestamp}`;

const inputPath = path.resolve(process.cwd(), inputFile);
if (!fs.existsSync(inputPath)) {
  console.error(`Input file not found: ${inputPath}`);
  process.exit(1);
}

const input = JSON.parse(fs.readFileSync(inputPath, 'utf8'));

if (!input.sources || typeof input.sources !== 'object') {
  console.error(`No "sources" field found in ${inputFile}`);
  process.exit(1);
}

const outDir = path.resolve(process.cwd(), outputArg);

fs.mkdirSync(outDir, { recursive: true });
console.log(`Created directory: ${outDir}`);

let count = 0;
for (const [filePath, entry] of Object.entries(input.sources)) {
  if (typeof entry.content !== 'string') {
    console.warn(`  Skipping ${filePath}: no "content" field`);
    continue;
  }

  const destPath = path.join(outDir, filePath);
  const destDir = path.dirname(destPath);

  // Prevent path traversal outside outDir
  const resolvedDest = path.resolve(destPath);
  if (!resolvedDest.startsWith(outDir + path.sep) && resolvedDest !== outDir) {
    console.warn(`  Skipping ${filePath}: path traversal detected`);
    continue;
  }

  fs.mkdirSync(destDir, { recursive: true });
  fs.writeFileSync(destPath, entry.content, 'utf8');
  console.log(`  Written: ${filePath}`);
  count++;
}

console.log(`\nDone. ${count} file(s) extracted to ${outDir}`);
