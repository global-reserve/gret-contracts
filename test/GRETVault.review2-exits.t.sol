// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {GRETVaultCase} from "./helpers/GRETVaultCase.sol";

/// @dev transfers always work; balanceOf can revert, return 0 or 31
/// bytes, or burn a fixed amount of gas before answering correctly.
contract OddBalanceToken is ERC20 {
    enum Mode {
        Normal,
        Revert,
        Empty,
        Short31,
        Burn
    }

    Mode public mode;
    uint256 public burnGas;

    constructor() ERC20("Odd balance", "ODD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function slash(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setBurn(uint256 gasToBurn) external {
        mode = Mode.Burn;
        burnGas = gasToBurn;
    }

    function rawBalanceOf(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOf(address account) public view override returns (uint256) {
        Mode m = mode;
        if (m == Mode.Revert) revert("balanceOf broken");
        if (m == Mode.Empty) {
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.Short31) {
            assembly {
                mstore(0, 0)
                return(0, 31)
            }
        }
        if (m == Mode.Burn) {
            uint256 start = gasleft();
            uint256 target = burnGas;
            while (start - gasleft() < target) {}
        }
        return super.balanceOf(account);
    }
}

/// @dev while `noop` is set, transfer returns true and moves nothing.
contract ToggleNoOpToken is ERC20 {
    bool public noop;

    constructor() ERC20("Toggle no-op", "TNO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setNoop(bool value) external {
        noop = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (noop) return true;
        return super.transfer(to, amount);
    }
}

contract Review2ExitsTest is GRETVaultCase {
    uint256 internal constant MAX = type(uint256).max;

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _setRedeemFee(GRETVault v, address recipient, uint256 fee) internal {
        vm.startPrank(GOVERNANCE);
        v.setFeeRecipient(recipient);
        v.proposeFees(0, fee);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        v.applyFees();
        assertEq(v.redeemFee(), fee);
    }

    /// @dev Vault [H, M]; Alice and Bob mint 1 GRET each with 2e18 H and `perShare` M.
    function _oddVault(uint256 perShare) internal returns (GRETVault v, OddBalanceToken m) {
        m = new OddBalanceToken();
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy;
        basket[1] = m;
        v = new GRETVault(basket, _pair(2e18, perShare), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : BOB;
            m.mint(user, 1e24);
            vm.startPrank(user);
            healthy.approve(address(v), MAX);
            m.approve(address(v), MAX);
            v.mint(SHARE, _pair(MAX, MAX), SHARE, 0);
            vm.stopPrank();
        }
    }

    function _liquidateBoth(GRETVault v) internal {
        vm.prank(GOVERNANCE);
        v.activateLiquidation();
        vm.prank(ALICE);
        v.convertToClaims(SHARE);
        vm.prank(BOB);
        v.convertToClaims(SHARE);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L05: a positive redemption fee keeps the supply from ever returning to zero
    // ---------------------------------------------------------------------------------------------

    function test_L05_soleHolderAndRecipientKeepsOneGret() public {
        vm.prank(ALICE);
        vault.mint(19e18, _pair(MAX, MAX), 0, 0);
        _setRedeemFee(vault, ALICE, 500);

        vm.prank(ALICE);
        vault.redeem(20e18, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 1e18, "supply after redeeming all");
        assertEq(vault.balanceOf(ALICE), 1e18, "Alice holds the whole supply");

        uint256[6] memory sizes = [uint256(1), 19, 20, 1e9, 0.5e18, 1e18];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 x = sizes[k];
            uint256 remaining = 1e18 - (x - x * 500 / 10_000);
            vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, remaining));
            vm.prank(ALICE);
            vault.redeem(x, _pair(0, 0), 0);
        }
        uint256[] memory held = vault.reserves();
        assertEq(held[0], 2e18);
        assertEq(held[1], 5e18);

        // A cut to zero applies at once and frees the last GRET.
        vm.prank(GOVERNANCE);
        vault.proposeFees(0, 0);
        vm.prank(ALICE);
        vault.redeem(1e18, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0, "supply empties only after the fee cut");
    }

    function test_L05_handOverDoesNotFreeLastHolder() public {
        vm.prank(ALICE);
        vault.mint(19e18, _pair(MAX, MAX), 0, 0);
        _setRedeemFee(vault, CAROL, 500);

        // Round 1: Alice holds 20 GRET = the whole supply; the fee goes to Carol.
        vm.prank(ALICE);
        vault.redeem(20e18, _pair(0, 0), 0);
        assertEq(vault.balanceOf(CAROL), 1e18);
        // Carol hands everything back; Alice again holds the whole supply.
        vm.prank(CAROL);
        vault.transfer(ALICE, 1e18);
        assertEq(vault.balanceOf(ALICE), vault.totalSupply());
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, 0.05e18));
        vm.prank(ALICE);
        vault.redeem(1e18, _pair(0, 0), 0);
    }

    function testFuzz_L05_positiveRedeemFeeNeverEmptiesSupply(uint256 fee, uint256 extra, uint256 x) public {
        fee = bound(fee, 1, 500);
        extra = bound(extra, 0, 1000e18);
        if (extra != 0) {
            vm.prank(ALICE);
            vault.mint(extra, _pair(MAX, MAX), 0, 0);
        }
        _setRedeemFee(vault, ALICE, fee);
        uint256 s = vault.totalSupply();
        x = bound(x, 1, s);
        vm.prank(ALICE);
        try vault.redeem(x, _pair(0, 0), 0) {
            assertGt(vault.totalSupply(), 0);
            assertGe(vault.totalSupply(), 1e18);
        } catch {}
        s = vault.totalSupply();
        vm.prank(ALICE);
        try vault.redeem(s, _pair(0, 0), 0) {
            assertGt(vault.totalSupply(), 0);
        } catch {}
        assertGe(vault.totalSupply(), 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L01: try/catch catches a revert in balanceOf, not malformed return data or missing code
    // ---------------------------------------------------------------------------------------------

    function _redeemCall(GRETVault v) internal returns (bool ok, bytes memory ret) {
        vm.prank(ALICE);
        (ok, ret) = address(v).call(abi.encodeCall(GRETVault.redeem, (SHARE, _pair(0, 0), 0)));
    }

    function test_L01_redeemCatchesOnlyARevert() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        uint256 snap = vm.snapshotState();

        m.setMode(OddBalanceToken.Mode.Revert);
        (bool ok,) = _redeemCall(v);
        assertTrue(ok, "reverting balanceOf: redeem goes ahead");
        assertEq(m.rawBalanceOf(ALICE), 1e24, "Alice got her 5e18 M back");
        vm.revertToState(snap);

        m.setMode(OddBalanceToken.Mode.Empty);
        bytes memory ret;
        (ok, ret) = _redeemCall(v);
        assertFalse(ok, "empty return: redeem reverts");
        assertEq(ret.length, 0, "with empty revert data");
        vm.prank(ALICE);
        assertTrue(m.transfer(CAROL, 1), "M transfers still work");
        // The only exit gives M up.
        vm.prank(ALICE);
        address[] memory skipped = new address[](1);
        skipped[0] = address(m);
        uint256[] memory paid = v.redeemSkipping(SHARE, _pair(0, 0), skipped, 0);
        assertEq(paid[0], 2e18);
        assertEq(paid[1], 0);
        vm.revertToState(snap);

        m.setMode(OddBalanceToken.Mode.Short31);
        (ok, ret) = _redeemCall(v);
        assertFalse(ok, "31-byte return: redeem reverts");
        assertEq(ret.length, 0);
        vm.revertToState(snap);

        vm.etch(address(m), "");
        (ok, ret) = _redeemCall(v);
        assertFalse(ok, "no code: redeem reverts");
        assertEq(ret.length, 0);
        vm.revertToState(snap);

        // Normal operation recovers after a write-off (no external call in writeOffComponent).
        m.setMode(OddBalanceToken.Mode.Empty);
        vm.prank(GOVERNANCE);
        v.proposeWriteOff(address(m));
        vm.warp(block.timestamp + 7 days);
        v.writeOffComponent(address(m));
        (ok,) = _redeemCall(v);
        assertTrue(ok, "after the write-off, redeem works without M");
    }

    function test_L01_liquidationClaimsOnlyCatchARevert() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        _liquidateBoth(v);
        uint256 snap = vm.snapshotState();

        // Control: a reverting balanceOf is paid in full, as documented.
        m.setMode(OddBalanceToken.Mode.Revert);
        assertEq(v.claimable(ALICE, 1), 5e18);
        vm.prank(ALICE);
        assertEq(v.claim(1, ALICE, 0), 5e18);
        // componentSurplus has no try: it reverts on a revert too, so sync and rescue do not
        // distinguish the two failure modes.
        (bool ok,) = address(v).staticcall(abi.encodeCall(GRETVault.componentSurplus, (1)));
        assertFalse(ok, "componentSurplus reverts on a reverting balanceOf too");
        vm.prank(GOVERNANCE);
        (ok,) = address(v).call(abi.encodeCall(GRETVault.sync, (address(m))));
        assertFalse(ok, "sync reverts on a reverting balanceOf too");
        vm.revertToState(snap);

        m.setMode(OddBalanceToken.Mode.Empty);
        bytes memory ret;
        (ok, ret) = address(v).staticcall(abi.encodeCall(GRETVault.claimable, (ALICE, 1)));
        assertFalse(ok, "claimable reverts on empty return");
        assertEq(ret.length, 0);
        vm.prank(ALICE);
        (ok, ret) = address(v).call(abi.encodeCall(GRETVault.claim, (1, ALICE, 0)));
        assertFalse(ok, "claim reverts on empty return");
        assertEq(ret.length, 0);
        assertEq(v.pendingRights(ALICE, 1), 5e18, "right stays pending");
        vm.prank(BOB);
        assertTrue(m.transfer(CAROL, 1), "M transfers still work");
        vm.prank(ALICE);
        assertEq(v.claim(0, ALICE, 0), 2e18, "the other component pays");
        // Once the token answers again, the right is paid.
        m.setMode(OddBalanceToken.Mode.Normal);
        vm.prank(ALICE);
        assertEq(v.claim(1, ALICE, 0), 5e18);
        vm.revertToState(snap);

        // No code: claim reverts; even if caught, SafeERC20 would refuse the transfer.
        vm.etch(address(m), "");
        vm.prank(ALICE);
        (ok, ret) = address(v).call(abi.encodeCall(GRETVault.claim, (1, ALICE, 0)));
        assertFalse(ok, "claim reverts without code");
    }

    function test_L01_guardMalformedBalanceStopsLossySwaps() public {
        OddBalanceToken m = new OddBalanceToken();
        MockERC20 b = new MockERC20("B", "B", 18);
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = healthy;
        basket[1] = b;
        basket[2] = m;
        GRETVault v = new GRETVault(basket, _three(2e18, 2e18, 2e18), GOVERNANCE);
        m.mint(ALICE, 1e24);
        b.mint(ALICE, 1e24);
        b.mint(REBALANCER, 1e24);
        vm.startPrank(ALICE);
        healthy.approve(address(v), MAX);
        b.approve(address(v), MAX);
        m.approve(address(v), MAX);
        v.mint(SHARE, _three(MAX, MAX, MAX), 0, 0);
        v.mint(9e18, _three(MAX, MAX, MAX), 0, 0);
        vm.stopPrank();
        vm.startPrank(REBALANCER);
        b.approve(address(v), MAX);
        vm.stopPrank();

        MockAggregator[3] memory feeds;
        address[] memory tokens = new address[](3);
        IChainlinkFeed[] memory feedList = new IChainlinkFeed[](3);
        for (uint256 i; i < 3; ++i) {
            feeds[i] = new MockAggregator(8, 100e8);
            tokens[i] = address(basket[i]);
            feedList[i] = IChainlinkFeed(address(feeds[i]));
        }
        ChainlinkPriceGuard guard = new ChainlinkPriceGuard(address(v), tokens, feedList, _three(1 days, 1 days, 1 days));
        _appoint(v, address(guard));
        for (uint256 i; i < 3; ++i) {
            feeds[i].setAnswer(100e8);
        }
        uint256 snap = vm.snapshotState();

        // Normal: a 1% loss passes.
        vm.prank(REBALANCER);
        v.swap(address(healthy), 1e18, address(b), 0.99e18);
        uint256 normalLoss = guard.weeklyLoss();
        vm.revertToState(snap);

        // Reverting balanceOf: M counts as zero and the loss weighs more.
        m.setMode(OddBalanceToken.Mode.Revert);
        vm.prank(REBALANCER);
        v.swap(address(healthy), 1e18, address(b), 0.99e18);
        uint256 revertLoss = guard.weeklyLoss();
        assertGt(revertLoss, normalLoss);
        vm.revertToState(snap);

        // Empty return: every swap with a loss reverts, though M is not part of the swap.
        m.setMode(OddBalanceToken.Mode.Empty);
        vm.prank(REBALANCER);
        (bool ok, bytes memory ret) =
            address(v).call(abi.encodeCall(GRETVault.swap, (address(healthy), 1e18, address(b), 0.99e18)));
        assertFalse(ok, "lossy swap reverts on empty return");
        assertEq(ret.length, 0);
        // A swap without a loss returns before the valuation.
        vm.prank(REBALANCER);
        v.swap(address(healthy), 1e18, address(b), 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L08: the caller's gas limit can force the catch branch of an expensive balanceOf
    // ---------------------------------------------------------------------------------------------

    function _scanClaim(GRETVault v, OddBalanceToken m, uint256 from, uint256 to, uint256 step, bool cool)
        internal
        returns (uint256 full, uint256 proRata, uint256 lowestFull, uint256 highestFull)
    {
        for (uint256 g = from; g <= to; g += step) {
            uint256 snap = vm.snapshotState();
            if (cool) {
                vm.cool(address(v));
                vm.cool(address(m));
            }
            uint256 before = m.rawBalanceOf(ALICE);
            vm.prank(ALICE);
            (bool ok,) = address(v).call{gas: g}(abi.encodeCall(GRETVault.claim, (1, ALICE, 0)));
            uint256 got = m.rawBalanceOf(ALICE) - before;
            vm.revertToState(snap);
            if (!ok) continue;
            if (got == 5e18) {
                ++full;
                if (lowestFull == 0) lowestFull = g;
                highestFull = g;
            } else {
                assertEq(got, 2.5e18, "a successful claim pays full or pro rata");
                ++proRata;
            }
        }
    }

    function test_L08_expensiveBalanceOfClaimFullPayout() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        _liquidateBoth(v);
        m.slash(address(v), 5e18); // shortfall: 5e18 left for 10e18 of rights
        m.setBurn(8_000_000);
        (uint256 full, uint256 proRata, uint256 lowestFull, uint256 highestFull) =
            _scanClaim(v, m, 1_000_000, 16_700_000, 250_000, false);
        assertGt(full, 0);
        assertGt(proRata, 0);
        assertEq(lowestFull, 4_500_000);
        assertEq(highestFull, 8_000_000);

        // The attack for real, then Bob is left with nothing claimable.
        vm.prank(ALICE);
        (bool ok,) = address(v).call{gas: lowestFull}(abi.encodeCall(GRETVault.claim, (1, ALICE, 0)));
        assertTrue(ok);
        assertEq(m.rawBalanceOf(address(v)), 0, "Alice took the whole remaining balance");
        assertEq(v.claimable(BOB, 1), 0);
        assertEq(v.pendingRights(BOB, 1), 5e18);
    }

    function test_L08_expensiveBalanceOfClaimFullPayoutColdState() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        _liquidateBoth(v);
        m.slash(address(v), 5e18);
        m.setBurn(8_000_000);
        (uint256 full, uint256 proRata, uint256 lowestFull, uint256 highestFull) =
            _scanClaim(v, m, 1_000_000, 16_700_000, 250_000, true);
        assertGt(full, 0);
        assertGt(proRata, 0);
        assertEq(lowestFull, 5_250_000);
        assertEq(highestFull, 8_000_000);
    }

    function test_L08_realisticBalanceOfCannotBeStarved() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        _liquidateBoth(v);
        m.slash(address(v), 5e18);
        m.setBurn(100_000);
        (uint256 full, uint256 proRata,,) = _scanClaim(v, m, 30_000, 300_000, 250, false);
        (uint256 full2, uint256 proRata2,,) = _scanClaim(v, m, 300_000, 1_500_000, 10_000, false);
        assertEq(full + full2, 0);
        assertGt(proRata + proRata2, 0);
    }

    function test_L08_expensiveBalanceOfRedeemSkipsLoss() public {
        (GRETVault v, OddBalanceToken m) = _oddVault(5e18);
        m.slash(address(v), 5e18); // unrecognized loss: 5e18 left for 10e18 of reserve
        m.setBurn(12_000_000);
        uint256 stale;
        uint256 recognized;
        uint256 lowestStale;
        for (uint256 g = 1_000_000; g <= 16_700_000; g += 250_000) {
            uint256 snap = vm.snapshotState();
            uint256 before = m.rawBalanceOf(ALICE);
            (bool ok,) = _redeemCallGas(v, g);
            uint256 got = m.rawBalanceOf(ALICE) - before;
            vm.revertToState(snap);
            if (!ok) continue;
            if (got == 5e18) {
                ++stale;
                if (lowestStale == 0) lowestStale = g;
            } else {
                assertEq(got, 2.5e18);
                ++recognized;
            }
        }
        assertGt(stale, 0);
    }

    function _redeemCallGas(GRETVault v, uint256 g) internal returns (bool ok, bytes memory ret) {
        vm.prank(ALICE);
        (ok, ret) = address(v).call{gas: g}(abi.encodeCall(GRETVault.redeem, (SHARE, _pair(0, 0), 0)));
    }

    /// @dev 11 components (10 mocks + the expensive one last, the attacker's best position): the
    /// lowest gas limit at which a redeem is paid on the stale reserve.
    function test_L08_elevenComponentRedeemNeedsMoreThanTheCap() public {
        OddBalanceToken m = new OddBalanceToken();
        IERC20[] memory basket = new IERC20[](11);
        uint256[] memory initial = new uint256[](11);
        uint256[] memory maxIn = new uint256[](11);
        uint256[] memory zero = new uint256[](11);
        for (uint256 i; i < 10; ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            basket[i] = t;
            t.mint(ALICE, 1e24);
            t.mint(BOB, 1e24);
        }
        basket[10] = m;
        m.mint(ALICE, 1e24);
        m.mint(BOB, 1e24);
        for (uint256 i; i < 11; ++i) {
            initial[i] = 1e18;
            maxIn[i] = MAX;
        }
        GRETVault v = new GRETVault(basket, initial, GOVERNANCE);
        for (uint256 u; u < 2; ++u) {
            address user = u == 0 ? ALICE : BOB;
            vm.startPrank(user);
            for (uint256 i; i < 11; ++i) {
                basket[i].approve(address(v), MAX);
            }
            v.mint(SHARE, maxIn, 0, 0);
            vm.stopPrank();
        }
        m.slash(address(v), 1e18);
        m.setBurn(40_000_000);
        // Below the burn, success on the stale reserve is monotone in the gas limit: binary search.
        uint256 lo = 1_000_000;
        uint256 hi = 39_000_000;
        assertFalse(_staleRedeem(v, m, zero, lo));
        assertTrue(_staleRedeem(v, m, zero, hi));
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            if (_staleRedeem(v, m, zero, mid)) hi = mid;
            else lo = mid;
        }
        uint256 lowestStale = hi;
        assertGt(lowestStale, 0);
        for (uint256 i; i < 11; ++i) {
            _coolList.push(basket[i]);
        }
        lo = 1_000_000;
        hi = 39_000_000;
        assertFalse(_staleRedeem(v, m, zero, lo));
        assertTrue(_staleRedeem(v, m, zero, hi));
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            if (_staleRedeem(v, m, zero, mid)) hi = mid;
            else lo = mid;
        }
        // Honest redeem cost with the same tokens, balanceOf cheap, cooled: what the rest costs.
        m.setMode(OddBalanceToken.Mode.Normal);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 11; ++i) {
            vm.cool(address(basket[i]));
        }
        vm.cool(address(v));
        vm.prank(ALICE);
        v.redeem(SHARE, zero, 0);
        vm.revertToState(snap);
    }

    IERC20[] internal _coolList;

    function _staleRedeem(GRETVault v, OddBalanceToken m, uint256[] memory zero, uint256 g)
        internal
        returns (bool stale)
    {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < _coolList.length; ++i) {
            vm.cool(address(_coolList[i]));
        }
        if (_coolList.length != 0) vm.cool(address(v));
        uint256 before = m.rawBalanceOf(ALICE);
        vm.prank(ALICE);
        (bool ok,) = address(v).call{gas: g}(abi.encodeCall(GRETVault.redeem, (SHARE, zero, 0)));
        stale = ok && m.rawBalanceOf(ALICE) - before == 1e18;
        vm.revertToState(snap);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-I01: P-2 cannot see a claim that a no-op transfer left undelivered
    // ---------------------------------------------------------------------------------------------

    function test_I01_noOpClaimIsInvisibleToP2() public {
        ToggleNoOpToken n = new ToggleNoOpToken();
        GRETVault v = new GRETVault(_oneToken(n), _one(100e18), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : BOB;
            n.mint(user, 100e18);
            vm.startPrank(user);
            n.approve(address(v), MAX);
            v.mint(SHARE, _one(MAX), SHARE, 0);
            vm.stopPrank();
        }
        _liquidateBoth(v);

        n.setNoop(true);
        vm.recordLogs();
        vm.prank(ALICE);
        uint256 paid = v.claim(0, ALICE, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 claimedTopic = keccak256("Claimed(address,uint256,address,uint256,uint256)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != claimedTopic) continue;
            (, uint256 amount, uint256 rights) = abi.decode(logs[i].data, (address, uint256, uint256));
            assertEq(amount, rights, "Claimed shows no cut");
            assertEq(amount, 100e18);
            seen = true;
        }
        assertTrue(seen);
        assertEq(paid, 100e18);
        assertEq(n.balanceOf(ALICE), 0, "Alice received nothing");
        assertEq(n.balanceOf(address(v)), 200e18);

        n.setNoop(false);
        assertEq(v.componentSurplus(0), 100e18, "the undelivered amount is ordinary surplus");
        uint256 snap = vm.snapshotState();

        // P-2 finds no cut (rights - amount = 0); ordinary surplus synced to every holder.
        vm.prank(BOB);
        v.claim(0, BOB, 0);
        vm.prank(GOVERNANCE);
        v.sync(address(n));
        vm.prank(ALICE);
        v.claim(0, ALICE, 0);
        vm.prank(BOB);
        v.claim(0, BOB, 0);
        assertEq(n.balanceOf(ALICE), 50e18);
        assertEq(n.balanceOf(BOB), 150e18);
        vm.revertToState(snap);

        // Reconstructed from the token's own transfers, rescue can return it in full.
        vm.prank(GOVERNANCE);
        v.rescue(address(n), ALICE, 100e18);
        vm.prank(BOB);
        v.claim(0, BOB, 0);
        assertEq(n.balanceOf(ALICE), 100e18);
        assertEq(n.balanceOf(BOB), 100e18);
    }

    function _oneToken(IERC20 t) internal pure returns (IERC20[] memory basket) {
        basket = new IERC20[](1);
        basket[0] = t;
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L04: a JIT mint before the last holder's redeemSkipping takes the skipped share
    // ---------------------------------------------------------------------------------------------

    function _aliceSkipsF() internal returns (uint256[] memory paid) {
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.prank(ALICE);
        paid = vault.redeemSkipping(SHARE, _pair(0, 0), skipped, 0);
    }

    function test_L04_jitMintCapturesSkippedShare() public {
        faulty.setBlocked(ALICE, true); // the issuer blocks Alice, the only holder
        uint256 snap = vm.snapshotState();

        // Baseline: the skipped share becomes surplus and governance can return it.
        _aliceSkipsF();
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.componentSurplus(1), 5e18);
        vm.prank(GOVERNANCE);
        vault.rescue(address(faulty), CAROL, 5e18);
        assertEq(faulty.rawBalanceOf(CAROL), 5e18);
        vm.revertToState(snap);

        // JIT: the rebalancer address (any holder of the basket) mints 1 GRET just before.
        address entrant = REBALANCER;
        uint256 hBefore = healthy.balanceOf(entrant);
        uint256 fBefore = faulty.rawBalanceOf(entrant);
        vm.prank(entrant);
        vault.mint(SHARE, _pair(MAX, MAX), SHARE, 0);
        _aliceSkipsF();
        assertEq(vault.reserves()[1], 10e18, "the skipped share stays in the reserve");
        assertEq(vault.componentSurplus(1), 0);
        vm.prank(entrant);
        vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(healthy.balanceOf(entrant), hBefore);
        assertEq(faulty.rawBalanceOf(entrant) - fBefore, 5e18, "entrant gains the skipped 5 F");
        assertEq(vault.componentSurplus(1), 0, "nothing left for governance to return");
        vm.revertToState(snap);

        // A mint pause first restores the baseline.
        vm.prank(GOVERNANCE);
        vault.setMintPaused(true);
        vm.expectRevert(GRETVault.MintIsPaused.selector);
        vm.prank(entrant);
        vault.mint(SHARE, _pair(MAX, MAX), SHARE, 0);
        _aliceSkipsF();
        assertEq(vault.componentSurplus(1), 5e18);
    }

    function test_L04_jitShareWhenSkipperIsNotLast() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(MAX, MAX), SHARE, 0);
        faulty.setBlocked(ALICE, true);
        address entrant = REBALANCER;
        uint256 fBefore = faulty.rawBalanceOf(entrant);
        vm.prank(entrant);
        vault.mint(SHARE, _pair(MAX, MAX), SHARE, 0);
        _aliceSkipsF();
        vm.prank(entrant);
        vault.redeem(SHARE, _pair(0, 0), 0);
        uint256 gain = faulty.rawBalanceOf(entrant) - fBefore;
        assertEq(gain, 2.5e18);
    }
}
