// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GRETVault} from "../contracts/GRETVault.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";

/// @notice Independent audit probe for liquidation conservation across mixed operations.
/// @dev The deliberately tiny reserve exposes integer rounding. The token is a test model,
/// not evidence about an issuer's transfer behavior. Five holders mix conversions, share
/// transfers, claims, balance losses, recoveries, syncs and rescues over thirty steps.
contract GRETVaultAuditLiquidationTest is Test {
    uint256 private constant SHARES = 1e18;
    uint256 private constant HOLDERS = 5;
    GRETVault private vault;
    MockFaultyERC20 private token;

    struct Ledger {
        uint256 inflow;
        uint256 paid;
        uint256 rescued;
        uint256 lost;
    }

    function setUp() public {
        token = new MockFaultyERC20("Audit component", "AUD", 18);
        IERC20[] memory basket = new IERC20[](1);
        basket[0] = token;
        uint256[] memory initial = new uint256[](1);
        initial[0] = 997;
        vault = new GRETVault(basket, initial, address(this));
        token.mint(_holder(0), initial[0]);
        vm.startPrank(_holder(0));
        token.approve(address(vault), initial[0]);
        vault.mint(SHARES, initial, SHARES, 0);
        for (uint256 i = 1; i < HOLDERS; ++i) vault.transfer(_holder(i), SHARES / HOLDERS);
        vm.stopPrank();
        vault.activateLiquidation();
    }

    function testFuzz_auditLiquidationConservesBackingAcrossRecoveries(uint256 seed) public {
        Ledger memory ledger;
        ledger.inflow = 997;
        for (uint256 step; step < 30; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address actor = _holder((seed >> 8) % HOLDERS);
            uint256 action = seed % 7;
            uint256 entropy = seed >> 32;
            if (action == 0) {
                uint256 amount = entropy % (vault.balanceOf(actor) + 1);
                if (amount != 0) {
                    vm.prank(actor);
                    vault.convertToClaims(amount);
                }
            } else if (action == 1) {
                uint256 amount = entropy % (vault.balanceOf(actor) + 1);
                vm.prank(actor);
                vault.transfer(_holder((seed >> 16) % HOLDERS), amount);
            } else if (action == 2) {
                _claim(actor, ledger);
            } else if (action == 3) {
                uint256 amount = entropy % (token.balanceOf(address(vault)) + 1);
                token.slash(address(vault), amount);
                ledger.lost += amount;
            } else if (action == 4) {
                uint256 amount = entropy % 2_001;
                token.mint(address(vault), amount);
                ledger.inflow += amount;
            } else if (action == 5) {
                vault.sync(address(token));
            } else {
                uint256 amount = entropy % (vault.componentSurplus(0) + 1);
                if (amount != 0) {
                    uint256 reserve = vault.reserves()[0];
                    uint256 consumed = vault.rightsClaimed()[0];
                    uint256 before = token.balanceOf(address(this));
                    vault.rescue(address(token), address(this), amount);
                    ledger.rescued += amount;
                    assertEq(token.balanceOf(address(this)) - before, amount, "rescue delivery");
                    assertEq(vault.reserves()[0], reserve, "rescue changed reserve");
                    assertEq(vault.rightsClaimed()[0], consumed, "rescue changed rights");
                    assertGe(token.balanceOf(address(vault)), reserve - consumed, "rescue took backing");
                }
            }
            _assertConservation(ledger);
        }

        // Exercise actual transfers for all pending holders, rather than relying only
        // on view quotes. Dust that rounds to zero remains pending by design (R-21).
        for (uint256 i; i < HOLDERS; ++i) {
            address actor = _holder(i);
            uint256 shares = vault.balanceOf(actor);
            if (shares != 0) {
                vm.prank(actor);
                vault.convertToClaims(shares);
            }
            _claim(actor, ledger);
            _assertConservation(ledger);
        }
        assertEq(vault.totalSupply(), 0, "unconverted shares");
    }

    function _claim(address actor, Ledger memory ledger) private {
        if (vault.claimable(actor, 0) == 0) return;
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        uint256 amount = vault.claim(0, actor, 0);
        assertEq(token.balanceOf(actor) - before, amount, "claim delivery");
        ledger.paid += amount;
    }

    function _assertConservation(Ledger memory ledger) private view {
        uint256 held = token.balanceOf(address(vault));
        assertEq(held + ledger.paid + ledger.rescued + ledger.lost, ledger.inflow, "physical ledger");
        uint256 converted;
        uint256 pending;
        uint256 payableNow;
        for (uint256 i; i < HOLDERS; ++i) {
            address actor = _holder(i);
            converted += vault.claimShares(actor);
            pending += vault.pendingRights(actor, 0);
            payableNow += vault.claimable(actor, 0);
        }
        uint256 consumed = vault.rightsClaimed()[0];
        assertEq(converted + vault.totalSupply(), SHARES, "share conservation");
        assertEq(vault.totalClaimed()[0], ledger.paid, "payout ledger");
        assertLe(ledger.paid, consumed, "payout exceeds consumed rights");
        assertLe(consumed + pending, vault.reserves()[0], "rights exceed reserve");
        assertLe(payableNow, held, "claims exceed balance");
    }

    function _holder(uint256 index) private pure returns (address) {
        return address(uint160(0xA000 + index));
    }
}
