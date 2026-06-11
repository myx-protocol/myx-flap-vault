---
name: extract-sources
description: "Extract source files from a Standard JSON input file into a directory. Use when: unpacking sources from a Standard JSON input, creating individual .sol files from input.json, extracting contract source files for inspection or editing, creating a parsed_src_<timestamp> directory from input.json sources."
argument-hint: "[--input <file>] [--output <dir>]"
---

# extract-sources Skill

Parse a Standard JSON input file and write each entry in `sources` as an individual file under an output directory, preserving the relative paths exactly as they appear in the JSON.

## Script

| Script | Purpose |
|---|---|
| [extract_sources.js](extract_sources.js) | Read input JSON, create output directory, and write each `sources` entry to its correct relative path |

---

## Usage

```bash
# Defaults: --input input.json  --output parsed_src_<unix-timestamp>
node extract_sources.js

# Custom input file
node extract_sources.js --input x.json

# Custom output directory
node extract_sources.js --output my_sources

# Both overridden
node extract_sources.js --input x.json --output my_sources
```

### Parameters

| Flag | Default | Description |
|---|---|---|
| `--input` | `input.json` | Path to the Standard JSON input file |
| `--output` | `parsed_src_<unix-timestamp>` | Output directory name or path |

**What it does:**
1. Reads the input file from the workspace root (or path given).
2. Resolves the output directory (generates a timestamped name if not specified).
3. For every key in `sources`, creates the necessary subdirectories and writes the `content` value to the matching relative path inside the output directory.
4. Prints a summary of all files written.

**Example output:**
```
Created directory: /workspace/workspaces/verify-solc/parsed_src_1744761600
  Written: src/Vaults/BurnDividendVault.sol
  Written: src/interface/IVaultSchemasV1.sol
  Written: src/interface/VaultBaseV2.sol
  ...

Done. 9 file(s) extracted to /workspace/workspaces/verify-solc/parsed_src_1744761600
```

---

## Notes

- When `--output` is omitted, each run creates a **new** timestamped directory so previous extractions are never overwritten.
- Files with a `content` field missing are skipped with a warning.
- Path traversal attempts (e.g. `../../evil.sol`) are detected and skipped for safety.
