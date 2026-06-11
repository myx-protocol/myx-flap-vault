const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function normalizeText(value) {
  return String(value || '').replace(/\r\n/g, '\n');
}

function hashText(value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex');
}

function findFirstDifference(a, b) {
  const minLen = Math.min(a.length, b.length);
  for (let i = 0; i < minLen; i += 1) {
    if (a[i] !== b[i]) {
      return i;
    }
  }
  if (a.length !== b.length) {
    return minLen;
  }
  return -1;
}

function toLineColumn(text, index) {
  const before = text.slice(0, index);
  const lines = before.split('\n');
  const line = lines.length;
  const column = lines[lines.length - 1].length + 1;
  return { line, column };
}

function main() {
  const inputPath = path.join(process.cwd(), 'input.json');
  const flattenedPath = process.argv[2]
    ? path.resolve(process.cwd(), process.argv[2])
    : path.join(process.cwd(), 'falltend.sol');

  let inputJson;
  let flattened;

  try {
    inputJson = fs.readFileSync(inputPath, 'utf8');
  } catch (err) {
    console.error(`Could not read input.json at ${inputPath}: ${err.message}`);
    process.exit(1);
  }

  try {
    flattened = fs.readFileSync(flattenedPath, 'utf8');
  } catch (err) {
    console.error(`Could not read flattened Solidity file at ${flattenedPath}: ${err.message}`);
    process.exit(1);
  }

  let standardInput;
  try {
    standardInput = JSON.parse(inputJson);
  } catch (err) {
    console.error(`input.json is not valid JSON: ${err.message}`);
    process.exit(1);
  }

  if (!standardInput.sources || typeof standardInput.sources !== 'object') {
    console.error('input.json does not contain a valid sources object.');
    process.exit(1);
  }

  const sourceEntries = Object.entries(standardInput.sources);
  if (!sourceEntries.length) {
    console.error('input.json sources is empty.');
    process.exit(1);
  }

  const candidates = sourceEntries.filter(([, src]) => src && typeof src.content === 'string');
  if (!candidates.length) {
    console.error('No inlined source content found in input.json sources[*].content.');
    process.exit(1);
  }

  const flatRaw = flattened;
  const flatNorm = normalizeText(flatRaw);
  const flatRawHash = hashText(flatRaw);
  const flatNormHash = hashText(flatNorm);

  for (const [sourceName, src] of candidates) {
    const sourceRaw = src.content;
    const sourceNorm = normalizeText(sourceRaw);

    if (flatRaw === sourceRaw) {
      console.log('Exact Match');
      console.log(`Flattened file matches input.json source exactly: ${sourceName}`);
      return;
    }

    if (flatNorm === sourceNorm) {
      console.log('Match After Newline Normalization');
      console.log(`Flattened file matches input.json source after CRLF/LF normalization: ${sourceName}`);
      return;
    }
  }

  const best = candidates[0];
  const [bestName, bestSrc] = best;
  const sourceNorm = normalizeText(bestSrc.content);
  const diffIndex = findFirstDifference(flatNorm, sourceNorm);

  console.log('Mismatch');
  console.log(`Flattened file does not match any input.json source content (${candidates.length} candidate source file(s) checked).`);

  if (diffIndex >= 0) {
    const flatPos = toLineColumn(flatNorm, diffIndex);
    const srcPos = toLineColumn(sourceNorm, diffIndex);
    console.log(`First difference against ${bestName} at index ${diffIndex}.`);
    console.log(`Flattened position: line ${flatPos.line}, column ${flatPos.column}`);
    console.log(`Input source position: line ${srcPos.line}, column ${srcPos.column}`);
  }

  console.log(`Flattened SHA-256 (raw): ${flatRawHash}`);
  console.log(`Flattened SHA-256 (normalized): ${flatNormHash}`);

  process.exit(2);
}

main();
