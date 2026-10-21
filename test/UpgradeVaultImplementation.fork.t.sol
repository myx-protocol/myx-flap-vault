// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {IFlapTriggerService} from "../src/flap/IFlapTriggerService.sol";

/// @dev Rehearses the refill-only-batch upgrade on a BSC mainnet fork against the LIVE factory,
///      beacon and vaults: Guardian switches the beacon, existing vault state survives byte for
///      byte, and the stalled HappyCoin vault (MYX quote, gas pool below its threshold) completes
///      refill + buyback through the REAL FlapTriggerService under its 2,000,000-gas callback cap.
///      Run with the live library linked:
///        forge test --match-path test/UpgradeVaultImplementation.fork.t.sol --fork-url <bsc rpc> \
///          --libraries src/lib/MyxVaultUISchema.sol:MyxVaultUISchema:0x10Fd858F44eEd0DF1dCA64fB0BE78cB54971CA77 -vv
contract UpgradeVaultImplementationForkTest is Test {
    MyxVaultFactory constant FACTORY = MyxVaultFactory(0xeaEEa9c17a5376497C44fE2a5F9c63FE3B23bf87);
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    IFlapTriggerService constant SERVICE = IFlapTriggerService(0xcf4EE25035CF883895110f367F5BA8172416a7F9);
    address constant SERVICE_OPERATOR = 0x80c83995FA87B20671B436aaA3a5211C02c1152e;
    MyxVault constant HAPPY = MyxVault(payable(0x548e7DE7BB5958F3Bd0706f913D9C2AB3d9c89c0));
    MyxVault constant MEMESTOCKS = MyxVault(payable(0xa111bDbec89d06199A97460b462561ccd8887554));

    struct Snapshot {
        address taxToken;
        address quoteToken;
        address creator;
        bytes32 poolId;
        uint256 pendingQuote;
        uint256 minProcessAmount;
        uint256 maxProcessAmount;
        uint256 gasThreshold;
        uint256 gasRefillAmount;
        uint256 totalLpMinted;
        uint256 totalRewardsForwarded;
        bool poolReady;
        bool hasPendingTrigger;
        address forwardTo;
        uint16 maxSlippageBps;
    }

    function _snap(MyxVault v) internal view returns (Snapshot memory s) {
        s.taxToken = v.taxToken();
        s.quoteToken = v.vaultQuoteToken();
        s.creator = v.creator();
        s.poolId = bytes32(abi.encode(v.poolId()));
        s.pendingQuote = v.pendingQuote();
        s.minProcessAmount = v.minProcessAmount();
        s.maxProcessAmount = v.maxProcessAmount();
        s.gasThreshold = v.gasThreshold();
        s.gasRefillAmount = v.gasRefillAmount();
        s.totalLpMinted = v.totalLpMinted();
        s.totalRewardsForwarded = v.totalRewardsForwarded();
        s.poolReady = v.poolReady();
        s.hasPendingTrigger = v.hasPendingTrigger();
        s.forwardTo = v.forwardTo();
        s.maxSlippageBps = v.maxSlippageBps();
    }

    function _upgrade() internal returns (address impl) {
        impl = address(new MyxVault());
        vm.prank(GUARDIAN);
        FACTORY.upgradeVaultImplementation(impl);
        assertEq(FACTORY.beacon().implementation(), impl, "beacon switched");
    }

    function _fire(MyxVault v) internal returns (bool success, bool refillOnly, uint256 gasUsed) {
        assertTrue(v.hasPendingTrigger(), "trigger pending");
        uint256 id = v.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        vm.recordLogs();
        vm.prank(SERVICE_OPERATOR);
        uint256 g0 = gasleft();
        SERVICE.trigger(id);
        gasUsed = g0 - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(v)) continue;
            if (logs[i].topics[0] == keccak256("ProcessTriggered(uint256,bool)")) {
                (, success) = abi.decode(logs[i].data, (uint256, bool));
            }
            if (logs[i].topics[0] == keccak256("RefillOnlyBatch(uint256)")) refillOnly = true;
        }
    }

    function test_upgrade_preservesLiveVaultState() public {
        Snapshot memory h0 = _snap(HAPPY);
        Snapshot memory m0 = _snap(MEMESTOCKS);
        _upgrade();
        assertEq(abi.encode(_snap(HAPPY)), abi.encode(h0), "HappyCoin vault state unchanged");
        assertEq(abi.encode(_snap(MEMESTOCKS)), abi.encode(m0), "MEMESTOCKS vault state unchanged");
        assertFalse(HAPPY.skipRefillOnce(), "new flag reads false on a live vault");
        assertFalse(MEMESTOCKS.skipRefillOnce());
    }

    function test_upgrade_unblocksHappyCoinUnder2MCallbacks() public {
        _upgrade();
        uint256 pending = HAPPY.pendingQuote();
        assertGe(pending, HAPPY.minProcessAmount(), "stalled backlog present");
        assertLt(HAPPY.gasBalance(), HAPPY.gasThreshold(), "gas pool below threshold: refill path");
        assertEq(HAPPY.totalLpMinted(), 0, "never bought back before the upgrade");

        HAPPY.requestProcess(); // fee paid from the vault's own gas pool
        (bool ok1, bool refillOnly, uint256 g1) = _fire(HAPPY);
        console2.log("callback 1 (refill-only) service tx gas:", g1);
        console2.log("gas pool after refill (wei):", HAPPY.gasBalance());
        assertTrue(ok1, "refill-only callback succeeded under the service cap");
        assertTrue(refillOnly, "callback 1 was a refill-only batch");
        assertTrue(HAPPY.skipRefillOnce());

        (bool ok2,, uint256 g2) = _fire(HAPPY);
        console2.log("callback 2 (buyback) service tx gas:", g2);
        console2.log("LP minted:", HAPPY.totalLpMinted());
        assertTrue(ok2, "buyback callback succeeded under the service cap");
        assertEq(HAPPY.pendingQuote(), 0, "backlog bought back");
        assertGt(HAPPY.totalLpMinted(), 0, "LP minted");
        assertFalse(HAPPY.skipRefillOnce());
    }

    function test_upgrade_onlyGuardian() public {
        address impl = address(new MyxVault());
        vm.expectRevert(bytes(unicode"Caller must be the guardian / 僅限守護者調用"));
        FACTORY.upgradeVaultImplementation(impl);
    }
}
