// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";

/// @notice Liquidation conservation across mixed operations.
/// @dev The deliberately tiny reserve exposes integer rounding. The token is a test model,
/// not evidence about an issuer's transfer behavior. Five holders mix conversions, share
/// transfers, claims, balance losses, recoveries and rejected component rescues over thirty steps.
contract GRETVaultLiquidationConservationTest is Test {
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
        token = new MockFaultyERC20("Component", "CMP", 18);
        IERC20[] memory basket = new IERC20[](1);
        basket[0] = token;
        uint256[] memory initial = new uint256[](1);
        initial[0] = 997;
        vault = new GRETVault(basket, initial, address(this));
        token.mint(_holder(0), initial[0]);
        vm.startPrank(_holder(0));
        token.approve(address(vault), initial[0]);
        vault.mint(SHARES, _holder(0), initial, SHARES, 0);
        for (uint256 i = 1; i < HOLDERS; ++i) vault.transfer(_holder(i), SHARES / HOLDERS);
        vm.stopPrank();
        vault.activateLiquidation();
    }

    function testFuzz_liquidationConservesBackingAcrossRecoveries(uint256 seed) public {
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
            } else {
                // Even unclaimed income belongs to holders; governance cannot withdraw it.
                vm.expectPartialRevert(GRETVault.BackingToken.selector);
                vault.rescue(address(token), address(this), 1);
            }
            _assertConservation(ledger);
        }

        // Exercise actual transfers for all pending holders, rather than relying only
        // on view quotes. Dust that rounds to zero remains pending by design.
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
            converted += vault.convertedShares(actor);
            pending += vault.pendingRights(actor, 0);
            payableNow += vault.claimable(actor, 0);
        }
        uint256 consumed = vault.totalConsumedRights()[0];
        assertEq(converted + vault.totalSupply(), SHARES, "share conservation");
        assertEq(vault.totalPaid()[0], ledger.paid, "payout ledger");
        assertLe(ledger.paid, consumed, "payout exceeds consumed rights");
        assertLe(consumed + pending, vault.reserves()[0], "rights exceed reserve");
        assertLe(payableNow, held, "claims exceed balance");
    }

    function _holder(uint256 index) private pure returns (address) {
        return address(uint160(0xA000 + index));
    }
}

/// @notice Shortfall claims: payouts do not depend on claim order, no component is rescued during a
/// shortfall, and the vault stays solvent after a recovery.
contract GRETVaultLiquidationShortfallTest is Test {
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
            vault.mint(vault.totalSupply() == 0 ? 1e18 : shares[k], holders[k], maxIn, 0, 0);
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

    /// During liquidation, component funds remain protected however many cut claims happen, so rescue
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
        address second = holders[(who + 1) % 3];
        _claim(second);
        vm.prank(GOVERNANCE);
        vm.expectRevert();
        vault.rescue(address(f), GOVERNANCE, 1);
        // The last one is still paid at least the fraction everyone got.
        address last = holders[(who + 2) % 3];
        uint256 rights = vault.pendingRights(last, 1);
        uint256 amount = _claim(last);
        assertGe(amount * held + held, rights * (held - held * cutBps / 10_000), "last holder below fraction");
    }

    /// After a cut, a recovery automatically raises everyone's rights in proportion; the vault stays
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
        uint256 total;
        for (uint256 k; k < 3; ++k) total += vault.claimable(holders[k], 1);
        assertLe(total, f.balanceOf(address(vault)), "claimable above balance");
        for (uint256 k = 1; k < 3; ++k) _claim(holders[k]);
        _claim(holders[0]);
        uint256[] memory r = vault.reserves();
        assertLe(vault.totalConsumedRights()[1], r[1], "rights above reserve");
    }

    function _claim(address who) internal returns (uint256 amount) {
        if (vault.claimable(who, 1) == 0) return 0;
        vm.prank(who);
        amount = vault.claim(1, who, 0);
    }
}
