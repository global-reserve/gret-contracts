// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";

/// @notice Targeted fuzz tests for liquidation behaviours not covered by the existing suite:
/// order independence of shortfall payouts, no surplus while a shortfall persists, and
/// recovery after cuts.
contract Review2LiquidationFuzzTest is Test {
    address internal constant GOVERNANCE = address(0x60F);
    address[3] internal holders = [address(0xA1), address(0xB2), address(0xC3)];
    GRETVault internal vault;
    MockERC20 internal h;
    MockFaultyERC20 internal f;

    function _setUp(uint256[3] memory shares) internal {
        h = new MockERC20("H", "H", 18);
        f = new MockFaultyERC20("F", "F", 8);
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = h;
        basket[1] = f;
        uint256[] memory init = new uint256[](2);
        init[0] = 3e18;
        init[1] = 7e8;
        vault = new GRETVault(basket, init, GOVERNANCE);
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;
        for (uint256 k; k < 3; ++k) {
            h.mint(holders[k], 1e40);
            f.mint(holders[k], 1e40);
            vm.startPrank(holders[k]);
            h.approve(address(vault), type(uint256).max);
            f.approve(address(vault), type(uint256).max);
            vault.mint(vault.totalSupply() == 0 ? 1e18 : shares[k], maxIn, 0, 0);
            vm.stopPrank();
        }
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        for (uint256 k; k < 3; ++k) {
            uint256 bal = vault.balanceOf(holders[k]);
            vm.prank(holders[k]);
            vault.convertToClaims(bal);
        }
    }

    /// Claims during a shortfall pay "the same fraction to everyone who has not claimed yet, in
    /// any order": each holder's payout depends on the order only by rounding.
    function testFuzz_shortfallPayoutsAreOrderIndependent(uint256 s1, uint256 s2, uint256 cutBps, uint256 perm)
        public
    {
        uint256[3] memory shares = [uint256(1e18), bound(s1, 1, 1e24), bound(s2, 1, 1e24)];
        _setUp(shares);
        uint256 held = f.balanceOf(address(vault));
        cutBps = bound(cutBps, 1, 9_999);
        f.slash(address(vault), held * cutBps / 10_000);

        uint256 snap = vm.snapshotState();
        uint256[3] memory forward;
        for (uint256 k; k < 3; ++k) forward[k] = _claim(holders[k]);
        uint256 paidForward = held - held * cutBps / 10_000 - f.balanceOf(address(vault));
        vm.revertToState(snap);

        uint256[3] memory order = perm % 2 == 0 ? [uint256(2), 0, 1] : [uint256(1), 2, 0];
        uint256[3] memory other;
        for (uint256 j; j < 3; ++j) other[order[j]] = _claim(holders[order[j]]);

        for (uint256 k; k < 3; ++k) {
            uint256 diff = forward[k] > other[k] ? forward[k] - other[k] : other[k] - forward[k];
            assertLe(diff, 2, "order changed a payout beyond rounding");
        }
        assertLe(paidForward, held - held * cutBps / 10_000, "paid above balance");
    }

    /// While a shortfall persists, no surplus appears however many cut claims happen, so rescue
    /// can never take what holders still waiting are owed.
    function testFuzz_noSurplusWhileShortfallPersists(uint256 s1, uint256 s2, uint256 cutBps, uint256 who) public {
        uint256[3] memory shares = [uint256(1e18), bound(s1, 1, 1e24), bound(s2, 1, 1e24)];
        _setUp(shares);
        uint256 held = f.balanceOf(address(vault));
        cutBps = bound(cutBps, 1, 9_999);
        f.slash(address(vault), held * cutBps / 10_000);
        who %= 3;
        address first = holders[who];
        _claim(first);
        assertEq(vault.componentSurplus(1), 0, "surplus during shortfall");
        address second = holders[(who + 1) % 3];
        _claim(second);
        assertEq(vault.componentSurplus(1), 0, "surplus during shortfall after two claims");
        vm.prank(GOVERNANCE);
        vm.expectRevert();
        vault.rescue(address(f), GOVERNANCE, 1);
        // The last one is still paid at least the fraction everyone got.
        address last = holders[(who + 2) % 3];
        uint256 rights = vault.pendingRights(last, 1);
        uint256 amount = _claim(last);
        assertGe(amount * held + held, rights * (held - held * cutBps / 10_000), "last holder below fraction");
    }

    /// After a cut, a recovery and a sync raise everyone's rights in proportion; the vault stays
    /// solvent for every pending right.
    function testFuzz_recoveryAfterCutsStaysSolvent(uint256 s1, uint256 s2, uint256 cutBps, uint256 back) public {
        uint256[3] memory shares = [uint256(1e18), bound(s1, 1, 1e24), bound(s2, 1, 1e24)];
        _setUp(shares);
        uint256 held = f.balanceOf(address(vault));
        cutBps = bound(cutBps, 1, 9_999);
        uint256 cut = held * cutBps / 10_000;
        f.slash(address(vault), cut);
        _claim(holders[0]);
        back = bound(back, 0, 2 * cut);
        f.mint(address(vault), back);
        vm.prank(GOVERNANCE);
        try vault.sync(address(f)) {} catch {}
        uint256 total;
        for (uint256 k; k < 3; ++k) total += vault.claimable(holders[k], 1);
        assertLe(total, f.balanceOf(address(vault)), "claimable above balance");
        for (uint256 k = 1; k < 3; ++k) _claim(holders[k]);
        _claim(holders[0]);
        uint256[] memory r = vault.reserves();
        assertLe(vault.rightsClaimed()[1], r[1], "rights above reserve");
    }

    function _claim(address who) internal returns (uint256 amount) {
        if (vault.claimable(who, 1) == 0) return 0;
        vm.prank(who);
        amount = vault.claim(1, who, 0);
    }
}
