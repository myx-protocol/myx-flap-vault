---
name: verify-solc
description: "Verify Solidity smart contracts against on-chain deployed bytecode. Use when: verifying a contract, checking if source matches deployment, comparing bytecode, detecting compiler version from deployed bytecode, fetching bytecode from contract address, running solc verification, checking partial match or metadata mismatch, diffing compiled vs deployed bytecode."
argument-hint: "<contract-address> or <rpc-url>"
---

# verify-solc Skill

Verify that the Solidity source matches a deployed contract on-chain — or against a locally-saved bytecode file.

The scripts accept either a **Standard JSON input file** (`.json`) or a **raw Solidity source file** (`.sol`). When a `.sol` file is given the scripts generate a minimal Standard JSON automatically. For contracts with imports or custom remappings, supply a full `input.json` instead.

## Scripts

| Script | Purpose |
|---|---|
| [verify_address.js](verify_address.js) | Fetch bytecode from chain by address, auto-detect compiler version, compile & compare |
| [verify.js](verify.js) | Compile the input and compare against `deployed_bytecode.txt` |
| [analyze_diff.js](analyze_diff.js) | Deep byte-level diff between compiled and deployed bytecode |
| [verify_source.js](verify_source.js) | Verify that a flattened `.sol` file matches the sources in a Standard JSON input |

---

## Workflows

### 1. Verify by contract address (recommended)

Requires only a contract address and an RPC endpoint. The script automatically detects the exact compiler version from the bytecode's CBOR metadata.

```bash
# Use an existing Standard JSON input (default: input.json)
node verify_address.js 0xYourContractAddress

# Use a specific Standard JSON file
node verify_address.js 0xYourContractAddress --input my_input.json

# Use a raw Solidity file (Standard JSON is generated automatically)
node verify_address.js 0xYourContractAddress --input MyContract.sol

# Override RPC if needed
node verify_address.js 0xYourContractAddress --rpc https://bsc-dataseed1.defibit.io/

# Or via env vars
ETH_RPC_URL=https://custom-rpc.example.com VERIFY_INPUT=MyContract.sol node verify_address.js 0xYourContractAddress
```

> Default RPC: `https://bsc-dataseed.binance.org/` (BNB Chain mainnet)
> Default input: `input.json` (or `VERIFY_INPUT` env var)

**Steps performed automatically:**
1. `eth_getCode` → fetches deployed bytecode
2. CBOR metadata parse → detects `solc` version (e.g. `0.8.24`)
3. Downloads that exact solc binary from `binaries.soliditylang.org`
4. If `--input` is a `.sol` file, generates a Standard JSON from it
5. Compiles with that version
6. Reports Exact Match / Partial Match / Mismatch

### 2. Verify against a saved bytecode file

Put the deployed bytecode (hex, with or without `0x` prefix) into `deployed_bytecode.txt`, then:

```bash
# Defaults: --input input.json  --bytecode deployed_bytecode.txt
node verify.js

# Use a specific Standard JSON file
node verify.js --input my_input.json

# Use a raw Solidity file
node verify.js --input MyContract.sol

# Custom bytecode file
node verify.js --bytecode other_bytecode.txt

# Both overridden
node verify.js --input MyContract.sol --bytecode other_bytecode.txt

# Or via env var
VERIFY_INPUT=MyContract.sol node verify.js
```

### Parameters

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--input` | `VERIFY_INPUT` | `input.json` | Standard JSON input **or** `.sol` source file |
| `--bytecode` | — | `deployed_bytecode.txt` | Path to the deployed bytecode file |
| `--rpc` | `ETH_RPC_URL` | BNB Chain public RPC | RPC endpoint (`verify_address.js` only) |

### 3. Deep diff analysis

When you get a Mismatch or Partial Match, run the diff script to pinpoint exactly which bytes differ:

```bash
node analyze_diff.js
```

### 4. Verify a flattened source file

Check that a flattened `.sol` file is consistent with the sources embedded in a Standard JSON input:

```bash
node verify_source.js path/to/Flattened.sol
```

---

## Match Results

| Output | Meaning |
|---|---|
| `Exact Match` | Deployed bytecode is byte-for-byte identical to compiled output |
| `Partial Match (metadata hash mismatch likely)` | Executable logic matches; only the CBOR metadata hash differs (different compiler settings, build environment, or IPFS hash) |
| `Mismatch` | Source does not correspond to the deployed contract |

---

## Input file selection

| Situation | Recommended flag |
|---|---|
| You have a Standard JSON (e.g. from Hardhat/Foundry artifacts) | `--input path/to/input.json` |
| You have a single self-contained `.sol` file | `--input path/to/MyContract.sol` |
| The contract has imports / remappings | Build a full `input.json` and use `--input input.json` |

> **Note:** When a `.sol` file is passed, a minimal Standard JSON is generated with no remappings. Compilation will fail if the contract imports external dependencies. In that case, generate a proper Standard JSON first (e.g. `forge inspect MyContract standard-json > input.json`).

---

## Compiler Version Handling

`verify_address.js` handles version mismatches automatically via the CBOR metadata embedded at the end of every `>=0.4.7` Solidity deployment. If the on-chain version differs from the locally installed `solc`, the correct binary is fetched from `binaries.soliditylang.org` at runtime.

For contracts compiled before CBOR metadata was available (pre-0.4.7) or non-Solidity contracts, use `verify.js` and manually ensure the right compiler is installed.

---

## Prerequisites

```bash
npm install        # installs solc
```
