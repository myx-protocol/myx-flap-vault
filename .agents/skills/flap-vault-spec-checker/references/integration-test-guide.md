# Integration Test Guide for Flap Vaults

## Rule

> The test suite **MUST** include integration tests that exercise all critical user-facing flows of the vault.

Integration tests run against a fully deployed vault contract (not mocked internals) and verify end-to-end behaviour including BNB transfers, state transitions, and access control.

## Why Integration Tests Are Required

| Risk | Mitigation |
|---|---|
| Silent reverts in `receive()` brick tax collection | Test that vault actually receives BNB |
| Guardian role accidentally revocable | Test revokeRole restrictions |
| Schema mismatch (vaultUISchema vs real ABI) | Test schema returns expected method count and names |
| Edge-case revert conditions missed on high-risk functions | Test revert paths for critical writes |
| State after multiple interactions | Test sequences of actions |

## Test File Naming Convention

```
test/
├── YourVaultUnit.t.sol          # Optional: pure unit tests for isolated logic
└── YourVaultIntegration.t.sol   # Required: end-to-end integration tests
```

## Required Test Categories

### 1. `receive()` Gas Test

```solidity

/// @dev receive() must stay within 1M gas budget
function testReceiveGasUnder1M() public {
    vm.deal(address(this), 1 ether);
    uint256 gasBefore = gasleft();
    (bool ok,) = address(vault).call{value: 1 ether}("");
    uint256 gasUsed = gasBefore - gasleft();
    assertTrue(ok);
    assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
}
```

### 2. Write Method Tests (focus on critical write functions)

```solidity
/// @dev Happy path: action succeeds and state updates correctly
function testMainAction_HappyPath() public {
    // arrange: fund vault, set up state
    // act: call the write method
    // assert: verify state change and events
}

/// @dev Revert path: action fails when precondition is violated
function testMainAction_RevertWhenNotAllowed() public {
    vm.expectRevert("expected error message");
    vault.mainAction();
}
```

### 3. View Method Tests (key views used by UI/integrations)

```solidity
/// @dev View returns correct initial value
function testViewMethod_InitialState() public {
    assertEq(vault.viewMethod(), expectedInitialValue);
}

/// @dev View returns updated value after state change
function testViewMethod_AfterAction() public {
    vault.mainAction();
    assertEq(vault.viewMethod(), expectedUpdatedValue);
}
```

### 4. `description()` Test

```solidity
/// @dev description() returns a different string before and after state changes
function testDescriptionChangesWithState() public {
    string memory before = vault.description();
    // trigger state change
    vault.mainAction();
    string memory after_ = vault.description();
    assertTrue(
        keccak256(bytes(before)) != keccak256(bytes(after_)),
        "description() should reflect state change"
    );
}
```

### 5. `vaultUISchema()` Test

```solidity
/// @dev vaultUISchema() returns non-empty schema with expected method count
function testVaultUISchema() public {
    VaultUISchema memory schema = vault.vaultUISchema();
    assertTrue(bytes(schema.vaultType).length > 0, "vaultType must be set");
    assertTrue(bytes(schema.description).length > 0, "description must be set");
    // replace N with your actual method count
    assertEq(schema.methods.length, N, "expected N methods in schema");
}
```

### 6. Guardian Access Control Tests

```solidity
/// @dev Guardian can call every privileged function
function testGuardianCanCallPrivilegedFunction() public {
    address guardian = /* resolve guardian for your chain */;
    vm.prank(guardian);
    vault.privilegedFunction(); // should NOT revert
}

/// @dev No one (not even admin) can revoke the guardian's role
function testCannotRevokeGuardianRole() public {
    address guardian = /* resolve guardian for your chain */;
    bytes32 role = /* the role the guardian holds */;
    vm.expectRevert(); // expect any revert
    vault.revokeRole(role, guardian);
}
```

## Complete Example: FreeCoinVault Integration Tests

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FreeCoin.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

contract FreeCoinVaultIntegrationTest is Test {
    FreeCoinVault vault;
    address taxToken = address(0x1234);

    uint256 constant MAX_REWARD = 0.1 ether;
    uint256 constant COOLDOWN  = 60 seconds;

    function setUp() public {
        vault = new FreeCoinVault(taxToken, MAX_REWARD, COOLDOWN);
        vm.deal(address(vault), 1 ether); // fund vault with BNB
    }

    // ── receive() ──────────────────────────────────────────────────────
    function testReceiveBNB() public {
        vm.deal(address(this), 0.5 ether);
        uint256 before = address(vault).balance;
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, before + 0.5 ether);
    }

    function testReceiveGasUnder1M() public {
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
    }

    // ── claim() write method ────────────────────────────────────────────
    function testClaim_HappyPath() public {
        address claimer = address(0x6789);
        vm.deal(claimer, 0);
        vm.prank(claimer);
        vault.claim();
        assertGt(claimer.balance, 0, "claimer should have received BNB");
        assertTrue(vault.hasClaimed(claimer));
    }

    function testClaim_RevertAlreadyClaimed() public {
        address claimer = address(0x6789);
        vm.prank(claimer);
        vault.claim();
        vm.expectRevert();
        vm.prank(claimer);
        vault.claim();
    }

    function testClaim_RevertCooldownNotElapsed() public {
        address claimer1 = address(0x6789);
        address claimer2 = address(0x6788);
        vm.prank(claimer1);
        vault.claim();
        vm.expectRevert();
        vm.prank(claimer2);
        vault.claim(); // cooldown still active
    }

    function testClaim_SucceedsAfterCooldown() public {
        address claimer1 = address(0x6789);
        address claimer2 = address(0x6788);
        vm.prank(claimer1);
        vault.claim();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(claimer2);
        vault.claim(); // should succeed
    }

    // ── view methods ───────────────────────────────────────────────────
    function testGetNextReward_BeforeClaims() public {
        uint256 reward = vault.getNextReward();
        assertEq(reward, MAX_REWARD); // balance (1 ether) > maxReward
    }

    function testGetNextClaimTime_Initial() public {
        assertEq(vault.getNextClaimTime(), 0);
    }

    function testGetLastClaimerAndReward_Initial() public {
        (address claimer, uint256 reward) = vault.getLastClaimerAndReward();
        assertEq(claimer, address(0));
        assertEq(reward, 0);
    }

    function testGetLastClaimerAndReward_AfterClaim() public {
        address claimer = address(0x6789);
        vm.prank(claimer);
        vault.claim();
        (address lastClaimer, uint256 lastReward) = vault.getLastClaimerAndReward();
        assertEq(lastClaimer, claimer);
        assertEq(lastReward, MAX_REWARD);
    }

    // ── description() ──────────────────────────────────────────────────
    function testDescriptionChangesAfterClaim() public {
        string memory before = vault.description();
        address claimer = address(0x6789);
        vm.prank(claimer);
        vault.claim();
        string memory after_ = vault.description();
        assertTrue(
            keccak256(bytes(before)) != keccak256(bytes(after_)),
            "description should change after first claim"
        );
    }

    // ── vaultUISchema() ────────────────────────────────────────────────
    function testVaultUISchema_Complete() public {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertTrue(bytes(schema.vaultType).length > 0);
        assertTrue(bytes(schema.description).length > 0);
        assertEq(schema.methods.length, 4, "FreeCoinVault should have 4 methods");
        assertEq(schema.methods[3].isWriteMethod, true); // claim() is write
    }
}
```

## Running the Tests

```bash
# Run all tests with verbose output
forge test -vv

# Run only integration tests
forge test --match-path "test/*Integration*" -vv

# Show gas usage per test
forge test --gas-report

# Check coverage
forge coverage
```

Reference integration suites (from [flap-sh/FlapVaultExample](https://github.com/flap-sh/FlapVaultExample)):

- [test/FreeCoin.mainnet.t.sol](https://github.com/flap-sh/FlapVaultExample/blob/main/test/FreeCoin.mainnet.t.sol)
- [test/FlapBSCFixture.sol](https://github.com/flap-sh/FlapVaultExample/blob/main/test/FlapBSCFixture.sol)

## Coverage Standard

Aim for practical coverage on critical flows (typically around **>= 60% line coverage** is acceptable when high-risk paths are thoroughly tested). All critical functions with custom revert conditions should be tested for both success and failure paths.

