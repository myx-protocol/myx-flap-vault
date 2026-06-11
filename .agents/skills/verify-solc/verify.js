const fs = require('fs');
const path = require('path');
const solc = require('solc');

// Parse CLI arguments
// Usage: node verify.js [--input <file>] [--bytecode <file>]
//   --input    Standard JSON input file or .sol source file  (default: input.json)
//   --bytecode Deployed bytecode file                        (default: deployed_bytecode.txt)
const args = process.argv.slice(2);
function getArg(flag) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : null;
}
const inputFile = getArg('--input') || process.env.VERIFY_INPUT || 'input.json';
const bytecodeFile = getArg('--bytecode') || 'deployed_bytecode.txt';

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

function normalizeBytecode(value) {
  return String(value || '')
    .trim()
    .replace(/^0x/i, '')
    .replace(/\s+/g, '')
    .toLowerCase();
}

function getExecutablePrefixFromCompiled(compiledBytecode) {
  if (!compiledBytecode || compiledBytecode.length < 4) {
    return null;
  }

  const metadataLenHex = compiledBytecode.slice(-4);
  const metadataLenBytes = Number.parseInt(metadataLenHex, 16);

  if (!Number.isFinite(metadataLenBytes) || metadataLenBytes < 0) {
    return null;
  }

  const metadataTotalHexChars = (metadataLenBytes + 2) * 2;

  if (metadataTotalHexChars > compiledBytecode.length) {
    return null;
  }

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
      if (!normalized) {
        continue;
      }

      results.push({
        sourceName,
        contractName,
        bytecode: normalized,
      });
    }
  }

  return results;
}

function main() {
  const inputPath = path.resolve(process.cwd(), inputFile);
  const deployedPath = path.join(process.cwd(), bytecodeFile);

  let standardInput;
  let deployedRaw;

  // Load standard input — supports .json and .sol files
  if (inputFile.endsWith('.sol')) {
    console.log(`Generating Standard JSON from Solidity file: ${inputFile}`);
    try {
      standardInput = buildStandardJsonFromSolFile(inputPath);
    } catch (err) {
      console.error(`Could not read ${inputFile}: ${err.message}`);
      process.exit(1);
    }
  } else {
    let inputJson;
    try {
      inputJson = fs.readFileSync(inputPath, 'utf8');
    } catch (err) {
      console.error(`Could not read ${inputFile} at ${inputPath}: ${err.message}`);
      process.exit(1);
    }
    try {
      standardInput = JSON.parse(inputJson);
    } catch (err) {
      console.error(`${inputFile} is not valid JSON: ${err.message}`);
      process.exit(1);
    }
  }

  try {
    deployedRaw = fs.readFileSync(deployedPath, 'utf8');
  } catch (err) {
    console.error(`Could not read ${bytecodeFile} at ${deployedPath}: ${err.message}`);
    process.exit(1);
  }

  let output;
  try {
    output = JSON.parse(solc.compile(JSON.stringify(standardInput)));
  } catch (err) {
    console.error(`solc compilation failed: ${err.message}`);
    process.exit(1);
  }

  if (output.errors && output.errors.length) {
    const hasCompilerError = output.errors.some((e) => e.severity === 'error');
    for (const e of output.errors) {
      const label = (e.severity || 'info').toUpperCase();
      console.log(`[SOLC ${label}] ${e.formattedMessage || e.message || ''}`.trim());
    }
    if (hasCompilerError) {
      process.exit(1);
    }
  }

  const deployed = normalizeBytecode(deployedRaw);
  if (!deployed) {
    console.error('deployed_bytecode.txt is empty or invalid.');
    process.exit(1);
  }

  const compiledContracts = collectCompiledContracts(output);
  if (!compiledContracts.length) {
    console.error('No compiled contracts found with evm.deployedBytecode.object.');
    process.exit(1);
  }

  for (const c of compiledContracts) {
    if (c.bytecode === deployed) {
      console.log('Exact Match');
      console.log(`Matched: ${c.sourceName}:${c.contractName}`);
      return;
    }
  }

  for (const c of compiledContracts) {
    const execPrefix = getExecutablePrefixFromCompiled(c.bytecode);
    if (!execPrefix) {
      continue;
    }

    if (deployed.startsWith(execPrefix)) {
      console.log('Partial Match (metadata hash mismatch likely)');
      console.log(`Matched executable logic: ${c.sourceName}:${c.contractName}`);
      return;
    }
  }

  console.log('Mismatch');
  console.log('No compiled contract bytecode matched the deployed bytecode.');
}

main();
