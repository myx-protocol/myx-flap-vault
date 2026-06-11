const fs = require('fs');
const path = require('path');
const solc = require('solc');

function normalize(value) {
  return String(value || '').trim().replace(/^0x/i, '').replace(/\s+/g, '').toLowerCase();
}

function stripMetadata(hex) {
  if (!hex || hex.length < 4) return hex;
  const metaLenHex = hex.slice(-4);
  const metaLenBytes = parseInt(metaLenHex, 16);
  if (!Number.isFinite(metaLenBytes) || metaLenBytes < 0) return hex;
  const totalHex = (metaLenBytes + 2) * 2;
  if (totalHex > hex.length) return hex;
  return hex.slice(0, hex.length - totalHex);
}

// Zero-out immutable reference slots in a hex string (in place, returns new string)
function zeroImmutableSlots(hex, immutableRefs) {
  if (!immutableRefs || Object.keys(immutableRefs).length === 0) return hex;
  let buf = hex.split('');
  for (const refs of Object.values(immutableRefs)) {
    for (const { start, length } of refs) {
      const hexStart = start * 2;
      const hexLen = length * 2;
      for (let i = hexStart; i < hexStart + hexLen; i++) {
        buf[i] = '0';
      }
    }
  }
  return buf.join('');
}

function longestCommonPrefixLen(a, b) {
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    if (a[i] !== b[i]) return i;
  }
  return len;
}

function countDiffNibbles(a, b) {
  let diff = 0;
  const minLen = Math.min(a.length, b.length);
  for (let i = 0; i < minLen; i++) {
    if (a[i] !== b[i]) diff++;
  }
  return diff + Math.abs(a.length - b.length);
}

function hexDiff(deployed, compiled, label, contextBytes = 20) {
  const maxLen = Math.max(deployed.length, compiled.length);
  const diffs = [];
  let i = 0;
  while (i < maxLen) {
    const dc = deployed.slice(i, i + 2) || '--';
    const cc = compiled.slice(i, i + 2) || '--';
    if (dc !== cc) {
      const start = i;
      let end = i + 2;
      while (end < maxLen) {
        const d2 = deployed.slice(end, end + 2) || '--';
        const c2 = compiled.slice(end, end + 2) || '--';
        if (d2 !== c2) { end += 2; continue; }
        // group nearby diffs within 8-byte window
        let found = false;
        for (let la = end + 2; la < Math.min(end + 18, maxLen); la += 2) {
          if ((deployed.slice(la, la + 2) || '--') !== (compiled.slice(la, la + 2) || '--')) {
            found = true; break;
          }
        }
        if (found) { end += 2; } else break;
      }
      diffs.push({ start, end });
      i = end;
    } else {
      i += 2;
    }
  }

  if (diffs.length === 0) return `  No byte differences found in ${label}.`;

  const lines = [];
  lines.push(`  Deployed bytes : ${deployed.length / 2}`);
  lines.push(`  Compiled bytes : ${compiled.length / 2}`);
  lines.push(`  Size delta     : ${(deployed.length - compiled.length) / 2} bytes`);
  lines.push(`  Diff regions   : ${diffs.length}`);
  lines.push('');

  const MAX_SHOW = 15;
  for (const { start, end } of diffs.slice(0, MAX_SHOW)) {
    const byteOff = start / 2;
    const regionBytes = (end - start) / 2;
    const ctxStart = Math.max(0, start - contextBytes * 2);
    const ctxEnd = Math.min(maxLen, end + contextBytes * 2);

    const dSlice = deployed.slice(ctxStart, ctxEnd);
    const cSlice = compiled.slice(ctxStart, ctxEnd);

    // Build marker line
    const markers = [];
    for (let k = ctxStart; k < ctxEnd; k += 2) {
      const d = deployed.slice(k, k + 2) || '--';
      const c = compiled.slice(k, k + 2) || '--';
      markers.push(d !== c ? '^^' : '  ');
    }

    lines.push(`  ── 0x${byteOff.toString(16).padStart(4,'0')} (byte ${byteOff}): ${regionBytes} byte(s) differ`);
    lines.push(`     deployed: ${dSlice}`);
    lines.push(`     compiled: ${cSlice}`);
    lines.push(`     markers : ${markers.join('')}`);
    lines.push('');
  }

  if (diffs.length > MAX_SHOW) {
    lines.push(`  ... and ${diffs.length - MAX_SHOW} more diff region(s) not shown`);
  }
  return lines.join('\n');
}

function main() {
  const inputJson = fs.readFileSync(path.join(process.cwd(), 'input.json'), 'utf8');
  const deployedRaw = fs.readFileSync(path.join(process.cwd(), 'deployed_bytecode.txt'), 'utf8');
  const deployed = normalize(deployedRaw);

  const standardInput = JSON.parse(inputJson);
  const output = JSON.parse(solc.compile(JSON.stringify(standardInput)));

  if (output.errors) {
    for (const e of output.errors) {
      if (e.severity === 'error') {
        console.error('[SOLC ERROR]', e.formattedMessage);
        process.exit(1);
      }
    }
  }

  // Collect all compiled contracts with immutable-aware normalization
  const candidates = [];
  for (const [sourceName, contracts] of Object.entries(output.contracts || {})) {
    for (const [contractName, data] of Object.entries(contracts || {})) {
      const raw = data?.evm?.deployedBytecode?.object;
      if (!raw) continue;

      const immutableRefs = data?.evm?.deployedBytecode?.immutableReferences || {};
      const hasImmutables = Object.keys(immutableRefs).length > 0;

      const compiled = normalize(raw);
      // Zero out immutable slots so we can compare logic only
      const compiledZeroed = zeroImmutableSlots(compiled, immutableRefs);
      const deployedZeroed = zeroImmutableSlots(deployed, immutableRefs);

      const compiledStripped = stripMetadata(compiledZeroed);
      const deployedStripped = stripMetadata(deployedZeroed);

      const exactMatch = compiled === deployed;
      const zeroedMatch = compiledZeroed === deployedZeroed;
      const strippedMatch = compiledStripped === deployedStripped;

      const prefixLen = longestCommonPrefixLen(deployedStripped, compiledStripped);
      const maxLen = Math.max(deployedStripped.length, compiledStripped.length);
      const similarity = maxLen > 0 ? prefixLen / maxLen : 0;
      const diffNibbles = countDiffNibbles(deployedStripped, compiledStripped);

      candidates.push({
        sourceName, contractName, compiled, compiledZeroed, compiledStripped,
        deployedZeroed, deployedStripped,
        immutableRefs, hasImmutables,
        exactMatch, zeroedMatch, strippedMatch,
        prefixLen, similarity, diffNibbles,
        deployedBytes: deployed.length / 2,
        compiledBytes: compiled.length / 2,
      });
    }
  }

  candidates.sort((a, b) => b.similarity - a.similarity || a.diffNibbles - b.diffNibbles);

  console.log('=== CONTRACT SIMILARITY RANKING ===\n');
  for (const c of candidates) {
    const pct = (c.similarity * 100).toFixed(2);
    const tag = c.exactMatch ? ' [EXACT MATCH]'
      : c.strippedMatch ? ' [IMMUTABLE+METADATA STRIPPED MATCH ✓]'
      : c.zeroedMatch ? ' [IMMUTABLE ZEROED MATCH]'
      : '';
    const immTag = c.hasImmutables ? ` [has ${Object.keys(c.immutableRefs).length} immutable ref(s)]` : '';
    console.log(`${c.sourceName}:${c.contractName}${tag}${immTag}`);
    console.log(`  Similarity: ${pct}%  DiffNibbles: ${c.diffNibbles}  Deployed: ${c.deployedBytes}B  Compiled: ${c.compiledBytes}B`);
  }

  const best = candidates[0];
  if (!best) { console.log('\nNo compiled contracts found.'); return; }

  console.log(`\n\n=== DEEP ANALYSIS: ${best.sourceName}:${best.contractName} ===\n`);

  if (best.exactMatch) {
    console.log('RESULT: EXACT MATCH — bytecodes are identical.'); return;
  }

  if (best.strippedMatch) {
    console.log('RESULT: MATCH after zeroing immutables + stripping metadata.');
    console.log('  → The logic bytecode is identical. Differences are ONLY due to:');
    if (best.hasImmutables) {
      console.log('    1. Immutable variable values embedded by the constructor');
      const refs = best.immutableRefs;
      for (const [astId, slots] of Object.entries(refs)) {
        for (const { start, length } of slots) {
          const val = deployed.slice(start * 2, (start + length) * 2);
          console.log(`       astId ${astId}: byte offset 0x${start.toString(16)} (${start}), length ${length}B, on-chain value = 0x${val}`);
        }
      }
    }
    console.log('    2. CBOR metadata hash (different compilation environment/source hash)');
    const deployedMeta = deployed.slice(stripMetadata(best.deployedZeroed).length);
    const compiledMeta = best.compiled.slice(stripMetadata(best.compiledZeroed).length);
    console.log(`       Deployed metadata: ${deployedMeta}`);
    console.log(`       Compiled metadata: ${compiledMeta}`);
    return;
  }

  if (best.zeroedMatch) {
    console.log('RESULT: MATCH after zeroing immutables (only metadata differs).');
    return;
  }

  // Still mismatched — show immutable info then diff
  if (best.hasImmutables) {
    console.log('NOTE: This contract has immutable variables. Their on-chain values embedded in deployed bytecode:');
    for (const [astId, slots] of Object.entries(best.immutableRefs)) {
      for (const { start, length } of slots) {
        const val = deployed.slice(start * 2, (start + length) * 2);
        console.log(`  astId ${astId}: byte 0x${start.toString(16)} (${start}), ${length}B = 0x${val}`);
      }
    }
    console.log('');
  }

  console.log('Remaining diff after zeroing immutables and stripping metadata:\n');
  console.log(hexDiff(best.deployedStripped, best.compiledStripped, 'immutable-zeroed+metadata-stripped'));

  // Size analysis
  if (best.deployedStripped.length !== best.compiledStripped.length) {
    const delta = (best.deployedStripped.length - best.compiledStripped.length) / 2;
    console.log(`\nSize difference (stripped): ${delta > 0 ? '+' : ''}${delta} bytes`);
    console.log('  Possible causes: different source code, optimizer runs, string literals, or extra functions.');
  }
}

main();
