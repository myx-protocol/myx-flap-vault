'use strict';

/**
 * verify_address.js
 *
 * Verify a deployed contract against input.json by supplying only the contract address.
 *
 * Usage:
 *   node verify_address.js <address> [--rpc <rpc_url>]
 *
 * The RPC URL can also be provided via the ETH_RPC_URL environment variable.
 *
 * The script will:
 *   1. Fetch the deployed bytecode from the chain via eth_getCode.
 *   2. Decode the CBOR metadata appended by the Solidity compiler to detect the exact
 *      compiler version used on-chain.
 *   3. Download and load that specific solc version remotely (handles version mismatch).
 *   4. Compile input.json with the detected compiler.
 *   5. Compare compiled bytecode against the deployed bytecode (exact then partial/metadata-strip).
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const solc = require('solc');

// ── bytecode helpers ──────────────────────────────────────────────────────────

function normalizeBytecode(value) {
  return String(value || '')
    .trim()
    .replace(/^0x/i, '')
    .replace(/\s+/g, '')
    .toLowerCase();
}

function getExecutablePrefixFromCompiled(compiledBytecode) {
  if (!compiledBytecode || compiledBytecode.length < 4) return null;

  const metadataLenHex = compiledBytecode.slice(-4);
  const metadataLenBytes = Number.parseInt(metadataLenHex, 16);
  if (!Number.isFinite(metadataLenBytes) || metadataLenBytes < 0) return null;

  const metadataTotalHexChars = (metadataLenBytes + 2) * 2;
  if (metadataTotalHexChars > compiledBytecode.length) return null;

  return compiledBytecode.slice(0, compiledBytecode.length - metadataTotalHexChars);
}

function collectCompiledContracts(output) {
  const results = [];
  const files = output && output.contracts ? output.contracts : {};

  for (const [sourceName, contractsByName] of Object.entries(files)) {
    for (const [contractName, contractData] of Object.entries(contractsByName || {})) {
      const object =
        contractData &&
        contractData.evm &&
        contractData.evm.deployedBytecode &&
        contractData.evm.deployedBytecode.object;

      const normalized = normalizeBytecode(object);
      if (!normalized) continue;

      results.push({ sourceName, contractName, bytecode: normalized });
    }
  }

  return results;
}

// ── CBOR metadata parser ──────────────────────────────────────────────────────

/**
 * Solidity appends CBOR-encoded metadata to deployed bytecode.
 * The last 2 bytes encode the byte-length of the CBOR payload (big-endian).
 * Since Solidity 0.5.9 the CBOR map contains a "solc" key whose value is a
 * 3-byte array [major, minor, patch].
 *
 * CBOR encoding of the key "solc":  0x64 0x73 0x6f 0x6c 0x63  (text(4) "solc")
 * CBOR encoding of the value bytes: 0x43 <major> <minor> <patch> (bytes(3))
 *
 * Returns [major, minor, patch] or null if not found.
 */
function extractSolcVersionFromBytecode(hexBytecode) {
  if (!hexBytecode || hexBytecode.length < 8) return null;

  const cborLenHex = hexBytecode.slice(-4);
  const cborLenBytes = parseInt(cborLenHex, 16);
  if (!Number.isFinite(cborLenBytes) || cborLenBytes <= 0) return null;

  const totalMetaHexChars = (cborLenBytes + 2) * 2;
  if (totalMetaHexChars > hexBytecode.length) return null;

  const cborHex = hexBytecode.slice(hexBytecode.length - totalMetaHexChars, hexBytecode.length - 4);
  const cborBuf = Buffer.from(cborHex, 'hex');

  // Scan for the CBOR-encoded text key "solc" (0x64 73 6f 6c 63)
  // followed by a 3-byte CBOR bytes value (0x43 <ma> <mi> <pa>)
  const solcKey = Buffer.from([0x64, 0x73, 0x6f, 0x6c, 0x63]);

  for (let i = 0; i <= cborBuf.length - solcKey.length - 4; i++) {
    let match = true;
    for (let j = 0; j < solcKey.length; j++) {
      if (cborBuf[i + j] !== solcKey[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      const next = i + solcKey.length;
      if (cborBuf[next] === 0x43) {
        // bytes(3)
        return [cborBuf[next + 1], cborBuf[next + 2], cborBuf[next + 3]];
      }
    }
  }

  return null;
}

// ── network helpers ───────────────────────────────────────────────────────────

function fetchUrl(url) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const req = mod.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        // follow one redirect
        resolve(fetchUrl(res.headers.location));
        return;
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      res.on('error', reject);
    });
    req.on('error', reject);
  });
}

function jsonRpcPost(rpcUrl, method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });

    let parsedUrl;
    try {
      parsedUrl = new URL(rpcUrl);
    } catch {
      reject(new Error(`Invalid RPC URL: ${rpcUrl}`));
      return;
    }

    const mod = parsedUrl.protocol === 'https:' ? https : http;
    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
      path: parsedUrl.pathname + parsedUrl.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    };

    const req = mod.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (e) {
          reject(new Error(`Failed to parse RPC response: ${e.message}`));
        }
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ── solc version resolution ───────────────────────────────────────────────────

function loadRemoteVersion(versionTag) {
  return new Promise((resolve, reject) => {
    solc.loadRemoteVersion(versionTag, (err, solcSnapshot) => {
      if (err) reject(err);
      else resolve(solcSnapshot);
    });
  });
}

async function resolveAndLoadSolc(major, minor, patch) {
  const versionStr = `${major}.${minor}.${patch}`;
  console.log(`Detected on-chain compiler version: ${versionStr}`);

  const listRaw = await fetchUrl('https://binaries.soliditylang.org/bin/list.json');
  let list;
  try {
    list = JSON.parse(listRaw);
  } catch (e) {
    throw new Error(`Failed to parse solc release list: ${e.message}`);
  }

  const releases = list.releases || {};
  if (!Object.prototype.hasOwnProperty.call(releases, versionStr)) {
    throw new Error(
      `solc version ${versionStr} not found in https://binaries.soliditylang.org/bin/list.json`
    );
  }

  // releases[versionStr] = "soljson-v0.8.24+commit.e11b9ed9.js"
  const fileName = releases[versionStr];
  const versionTag = fileName.replace(/^soljson-/, '').replace(/\.js$/, '');

  console.log(`Loading solc ${versionTag} from binaries.soliditylang.org …`);
  return loadRemoteVersion(versionTag);
}

// ── main ──────────────────────────────────────────────────────────────────────

// ── input helpers ─────────────────────────────────────────────────────────────

/**
 * Build a minimal Standard JSON input from a single .sol file.
 * Imports won't be resolved; use a full input.json for contracts with dependencies.
 */
function buildStandardJsonFromSolFile(solFilePath) {
  const content = fs.readFileSync(solFilePath, 'utf8');
  const fileName = path.basename(solFilePath);
  return {
    language: 'Solidity',
    sources: { [fileName]: { content } },
    settings: {
      outputSelection: { '*': { '*': ['evm.deployedBytecode'] } },
    },
  };
}

/**
 * Load standard JSON input from either a .json or a .sol file.
 * If a .sol file is given, generates a minimal Standard JSON automatically.
 */
function loadStandardInput(inputFile) {
  const inputPath = path.resolve(process.cwd(), inputFile);

  if (inputFile.endsWith('.sol')) {
    console.log(`Generating Standard JSON from Solidity file: ${inputFile}`);
    try {
      return buildStandardJsonFromSolFile(inputPath);
    } catch (err) {
      console.error(`Could not read ${inputFile}: ${err.message}`);
      process.exit(1);
    }
  }

  let raw;
  try {
    raw = fs.readFileSync(inputPath, 'utf8');
  } catch (err) {
    console.error(`Could not read ${inputFile} at ${inputPath}: ${err.message}`);
    process.exit(1);
  }

  try {
    return JSON.parse(raw);
  } catch (err) {
    console.error(`${inputFile} is not valid JSON: ${err.message}`);
    process.exit(1);
  }
}

// ── main ──────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  let address = null;
  let rpcUrl = process.env.ETH_RPC_URL || 'https://bsc-dataseed.binance.org/';
  let inputFile = process.env.VERIFY_INPUT || 'input.json';

  for (let i = 0; i < args.length; i++) {
    if ((args[i] === '--rpc' || args[i] === '-r') && args[i + 1]) {
      rpcUrl = args[++i];
    } else if ((args[i] === '--input' || args[i] === '-i') && args[i + 1]) {
      inputFile = args[++i];
    } else if (!address && /^0x[0-9a-fA-F]{40}$/i.test(args[i])) {
      address = args[i].toLowerCase();
    }
  }

  if (!address) {
    console.error('Usage: node verify_address.js <address> [--rpc <rpc_url>] [--input <file>]');
    console.error('       --input  Standard JSON or .sol file  (default: input.json)');
    console.error('       ETH_RPC_URL / VERIFY_INPUT env vars can be used instead');
    process.exit(1);
  }

  // 1. Fetch deployed bytecode via eth_getCode
  console.log(`Fetching bytecode for ${address} on ${rpcUrl} …`);
  let rpcResult;
  try {
    rpcResult = await jsonRpcPost(rpcUrl, 'eth_getCode', [address, 'latest']);
  } catch (err) {
    console.error(`RPC request failed: ${err.message}`);
    process.exit(1);
  }

  if (rpcResult.error) {
    console.error(`RPC error: ${JSON.stringify(rpcResult.error)}`);
    process.exit(1);
  }

  const deployedHex = normalizeBytecode(rpcResult.result);
  if (!deployedHex) {
    console.error('No bytecode at that address (EOA or non-existent contract).');
    process.exit(1);
  }

  // 2. Detect compiler version from CBOR metadata
  const versionTriple = extractSolcVersionFromBytecode(deployedHex);
  if (!versionTriple) {
    console.error(
      'Could not detect solc version from bytecode metadata.\n' +
        'The contract may pre-date metadata embedding (< 0.4.7) or use a non-Solidity compiler.'
    );
    process.exit(1);
  }

  // 3. Load the correct solc version
  let solcInstance;
  try {
    solcInstance = await resolveAndLoadSolc(...versionTriple);
  } catch (err) {
    console.error(`Failed to load solc: ${err.message}`);
    process.exit(1);
  }

  // 4. Read and compile input
  console.log(`Reading input from: ${inputFile}`);
  const standardInput = loadStandardInput(inputFile);

  let output;
  try {
    output = JSON.parse(solcInstance.compile(JSON.stringify(standardInput)));
  } catch (err) {
    console.error(`Compilation failed: ${err.message}`);
    process.exit(1);
  }

  if (output.errors && output.errors.length) {
    const hasError = output.errors.some((e) => e.severity === 'error');
    for (const e of output.errors) {
      const label = (e.severity || 'info').toUpperCase();
      console.log(`[SOLC ${label}] ${(e.formattedMessage || e.message || '').trim()}`);
    }
    if (hasError) process.exit(1);
  }

  // 5. Compare
  const compiledContracts = collectCompiledContracts(output);
  if (!compiledContracts.length) {
    console.error('No compiled contracts found with evm.deployedBytecode.object.');
    process.exit(1);
  }

  for (const c of compiledContracts) {
    if (c.bytecode === deployedHex) {
      console.log('Exact Match');
      console.log(`Matched: ${c.sourceName}:${c.contractName}`);
      return;
    }
  }

  for (const c of compiledContracts) {
    const execPrefix = getExecutablePrefixFromCompiled(c.bytecode);
    if (!execPrefix) continue;

    if (deployedHex.startsWith(execPrefix)) {
      console.log('Partial Match (metadata hash mismatch likely)');
      console.log(`Matched executable logic: ${c.sourceName}:${c.contractName}`);
      return;
    }
  }

  console.log('Mismatch');
  console.log('No compiled contract bytecode matched the deployed bytecode.');
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(1);
});
