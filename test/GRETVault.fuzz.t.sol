// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @notice Property-based tests over arbitrary amounts and prior vault states.
contract GRETVaultFuzzTest is Test {
    MockERC20[3] internal tokens;
    GRETVault internal vault;
    address internal constant GOVERNANCE = address(0x60F);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        tokens[0] = new MockERC20("Mock A", "MA", 18);
        tokens[1] = new MockERC20("Mock B", "MB", 8);
        tokens[2] = new MockERC20("Mock C", "MC", 6);
        IERC20[] memory components = new IERC20[](3);
        uint256[] memory initialAmounts = new uint256[](3);
        initialAmounts[0] = 2e18;
        initialAmounts[1] = 1e5;
        initialAmounts[2] = 7;
        for (uint256 i; i < 3; ++i) {
            components[i] = IERC20(address(tokens[i]));
        }
        vault = new GRETVault(components, initialAmounts, GOVERNANCE);

        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 2; ++k) {
                address user = k == 0 ? ALICE : BOB;
                tokens[i].mint(user, 1e40);
                vm.prank(user);
                tokens[i].approve(address(vault), type(uint256).max);
            }
        }
        uint256 initialShares = vault.INITIAL_SHARES();
        vm.prank(ALICE);
        vault.mint(initialShares, _filled(type(uint256).max), 0, 0);
    }

    /// Entering and leaving right away never returns more of any component than was paid,
    /// whatever the previous supply, donations and share size.
    function testFuzz_mintThenRedeemNeverProfits(uint256 otherShares, uint256 donation, uint256 shares) public {
        otherShares = bound(otherShares, 1, 1e24);
        vm.prank(ALICE);
        vault.mint(otherShares, _filled(type(uint256).max), 0, 0);
        donation = bound(donation, 0, 1e24);
        if (donation != 0) {
            tokens[0].mint(address(vault), donation);
            vm.prank(GOVERNANCE);
            vault.sync(address(tokens[0]));
        }

        shares = bound(shares, 1, 1e24);
        uint256[3] memory before = _balances(BOB);
        vm.startPrank(BOB);
        vault.mint(shares, _filled(type(uint256).max), 0, 0);
        vault.redeem(shares, _filled(0), 0);
        vm.stopPrank();

        uint256[3] memory afterRoundtrip = _balances(BOB);
        for (uint256 i; i < 3; ++i) {
            assertLe(afterRoundtrip[i], before[i], "roundtrip profit");
        }
    }

    /// Converting in two steps pays exactly the same as converting everything at once.
    function testFuzz_splitConversionMatchesSingleConversion(uint256 first, uint256 second) public {
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        uint256 balance = vault.balanceOf(ALICE);
        first = bound(first, 1, balance - 1);
        second = bound(second, 1, balance - first);
        uint256[] memory reserves = vault.reserves();
        uint256 supply = vault.liquidationSupply();

        vm.startPrank(ALICE);
        vault.convertToClaims(first);
        for (uint256 i; i < 3; ++i) {
            if (vault.claimable(ALICE, i) != 0) vault.claim(i, ALICE, 0);
        }
        vault.convertToClaims(second);
        for (uint256 i; i < 3; ++i) {
            if (vault.claimable(ALICE, i) != 0) vault.claim(i, ALICE, 0);
        }
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            assertEq(vault.claimed(ALICE, i), Math.mulDiv(first + second, reserves[i], supply), "split conversion");
        }
    }

    /// Redemption pays exactly the rounded-down proportional amount and never more than the reserve.
    function testFuzz_redeemPaysFloorOfProportion(uint256 otherShares, uint256 shares) public {
        otherShares = bound(otherShares, 1, 1e24);
        vm.prank(BOB);
        vault.mint(otherShares, _filled(type(uint256).max), 0, 0);
        uint256 balance = vault.balanceOf(ALICE);
        shares = bound(shares, 1, balance);
        uint256[] memory reserves = vault.reserves();
        uint256 supply = vault.totalSupply();

        // BOB keeps his GRET, so a redemption leaving less than MIN_SUPPLY must be rejected.
        if (supply - shares < vault.MIN_SUPPLY()) {
            vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, supply - shares));
            vm.prank(ALICE);
            vault.redeem(shares, _filled(0), 0);
            return;
        }
        vm.prank(ALICE);
        uint256[] memory out = vault.redeem(shares, _filled(0), 0);

        for (uint256 i; i < 3; ++i) {
            assertEq(out[i], Math.mulDiv(shares, reserves[i], supply), "redeem amount");
            assertLe(out[i], reserves[i], "redeem above reserve");
        }
    }

    function _filled(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            values[i] = value;
        }
    }

    function _balances(address account) internal view returns (uint256[3] memory balances) {
        for (uint256 i; i < 3; ++i) {
            balances[i] = tokens[i].balanceOf(account);
        }
    }
}
