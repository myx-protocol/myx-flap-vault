# Flap Tax Vault V2 — Specification Overview

## What Is a Flap Vault?

A Flap Tax Vault is a smart contract that receives BNB tax revenue collected by the Flap Portal from a tax token's trading activity, and processes that revenue according to custom logic (buybacks, distributions, staking rewards, etc.).

Anyone can build and deploy a custom vault — no whitelisting or registration is needed. The vault just needs to implement the correct interfaces.

## Core Contracts in `src/flap/` (DO NOT MODIFY)

| File | Purpose |
|---|---|
| `VaultBase.sol` | Abstract base for all vaults. Provides `_getPortal()`, `_getGuardian()`, and `description()` abstract |
| `VaultBaseV2.sol` | Extends VaultBase with `vaultUISchema()` — required for new vaults |
| `VaultFactoryBaseV2.sol` | Abstract base for vault factories. Provides `vaultDataSchema()` and `_getVaultPortal()` |
| `IVaultFactory.sol` | Interface all factories must implement (`newVault`, `isQuoteTokenSupported`) |
| `IVaultPortal.sol` | Interface for the Flap VaultPortal |
| `IPortal.sol` | Interface for the Flap Portal |
| `IVaultSchemasV1.sol` | Shared struct definitions: `FieldDescriptor`, `VaultDataSchema`, `VaultUISchema`, `VaultMethodSchema`, `ApproveAction` |

## Key Addresses

### BNB Chain (chain ID 56)
| Contract | Address |
|---|---|
| Portal | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` |
| VaultPortal | `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` |
| Guardian | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` |

### BNB Testnet (chain ID 97)
| Contract | Address |
|---|---|
| Portal | `0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9` |
| VaultPortal | `0x027e3704fC5C16522e9393d04C60A3ac5c0d775f` |
| Guardian | `0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950` |

## Vault Contract Requirements

### Required Implementation

```
VaultBaseV2
  ├── description() → dynamic string about vault state  [REQUIRED]
  ├── vaultUISchema() → VaultUISchema struct            [REQUIRED by V2]
  └── receive() external payable                        [REQUIRED, ≤1M gas]
```

### Enforcement Rules Summary

1. **`receive()` ≤ 1,000,000 gas** — keep it simple, delegate work to explicit calls
2. **Integration tests required** — every public function must have at least one test
3. **Guardian access** — all privileged functions must be callable by Guardian
4. **Guardian role irrevocable** — override `revokeRole` to protect guardian
5. **`newVault()` only from VaultPortal** — check `msg.sender == _getVaultPortal()`
6. **`src/flap/` immutable** — never edit files in this directory

## UI Schema (`vaultUISchema`) Field Types

| `fieldType` | Description | UI Widget |
|---|---|---|
| `string` | UTF-8 text | Text input |
| `address` | 20-byte Ethereum address | Address input with checksum |
| `uint16` | 0–65535 integer | Number input |
| `uint128` | Large integer | Number input |
| `uint256` | Very large integer | Big-number input |
| `time` | Unix timestamp (uint256 alias) | Date/time picker (input) or human-readable clock (output) |
| `bool` | True/false | Checkbox |
| `bytes` | Arbitrary bytes | Hex input |
| `bytes32` | 32-byte hash | Hex input (32 bytes) |

## UI Rendering Algorithm

1. Call `vault.vaultUISchema()` → displays vault type badge + description
2. Polls `vault.description()` periodically as a live status banner
3. For each `VaultMethodSchema` in `schema.methods`:
   - If `isWriteMethod == false` → render query panel (call immediately if no inputs)
   - If `isWriteMethod == true` → render form + Submit button
   - Handle `approvals` by calling `token.approve` before the write transaction
4. Methods rendered in array order

## Deployment Workflow

1. Implement vault + factory following V2 spec
2. Deploy factory to BNB Chain or Testnet
3. Go to [flap.sh](https://flap.sh) to launch your token using your factory address — no registration required

