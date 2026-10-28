// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {ChainlinkPriceGuard} from "../contracts/ChainlinkPriceGuard.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {GRETVaultCase} from "./helpers/GRETVaultCase.sol";

/// @dev Governance and economics findings of the second security review
/// (docs/audits/2026-10-28-GRETVault-review.md).

/// Executes a ready write-off and mints in the same transaction.
contract WriteOffBundler {
    function bundle(GRETVault vault, address token, uint256 shares) external returns (uint256 minted) {
        IERC20[] memory tokens = vault.components();
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.writeOffComponent(token);
        uint256[] memory maxIn = new uint256[](tokens.length);
        for (uint256 i; i < maxIn.length; ++i) {
            maxIn[i] = type(uint256).max;
        }
        (minted,) = vault.mint(shares, maxIn, 0, vault.basketVersion());
    }

    function redeemAll(GRETVault vault) external returns (uint256[] memory) {
        return vault.redeem(
            vault.balanceOf(address(this)), new uint256[](vault.componentCount()), vault.basketVersion()
        );
    }
}

/// A holder wallet that reads the basket version when its redemption executes.
contract VersionReadingWallet {
    function mintBasket(GRETVault vault, uint256 shares) external {
        IERC20[] memory tokens = vault.components();
        uint256[] memory maxIn = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
            maxIn[i] = type(uint256).max;
        }
        vault.mint(shares, maxIn, shares, vault.basketVersion());
    }

    function redeemNow(GRETVault vault, uint256 shares) external returns (uint256[] memory) {
        return vault.redeem(shares, new uint256[](vault.componentCount()), vault.basketVersion());
    }
}

/// Any contract can be announced as a component.
contract Junk {}

contract Review2GovernanceTest is GRETVaultCase {
    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L03: a ready write-off executed atomically with a mint
    // ---------------------------------------------------------------------------------------------

    function _freezeAndProposeWriteOff() internal returns (uint256 readyAt) {
        // F's issuer freezes the vault: nobody can mint, because mint must pull F.
        faulty.setBlocked(address(vault), true);
        vm.expectRevert(abi.encodeWithSelector(MockFaultyERC20.AccountBlocked.selector, address(vault)));
        vm.prank(BOB);
        vault.mint(SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        readyAt = vault.writeOffReadyAt(address(faulty));
    }

    function test_L03_atomicWriteOffAndMintBeatsReactivePause() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt);
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        assertEq(entrant.bundle(vault, address(faulty), 9 * SHARE), 9 * SHARE);
        assertEq(healthy.balanceOf(address(entrant)), 0, "entrant paid 18 H");
        assertEq(faulty.balanceOf(address(entrant)), 0, "entrant paid no F");

        // Governance reacts in the next block, as P-5 at 219b6a4 reads: too late.
        vm.roll(block.number + 1);
        vm.startPrank(GOVERNANCE);
        vault.setMintPaused(true);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NoPendingWriteOff.selector, address(faulty)));
        vault.cancelWriteOff(address(faulty));
        vm.stopPrank();

        // F recovers and governance syncs it at once (P-5).
        faulty.setBlocked(address(vault), false);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        uint256[] memory got = entrant.redeemAll(vault);
        vm.prank(ALICE);
        uint256[] memory alice = vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(got[0], 18e18);
        assertEq(got[1], 45e17);
        assertEq(alice[0], 2e18);
        assertEq(alice[1], 5e17);
    }

    /// The entry is a free option: if F never recovers, the entrant leaves with exactly what it paid.
    function test_L03_entrantLosesNothingIfNoRecovery() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt);
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        entrant.bundle(vault, address(faulty), 9 * SHARE);
        uint256[] memory got = entrant.redeemAll(vault); // F still frozen; its reserve is zero, so it is not called
        assertEq(got[0], 18e18);
        assertEq(got[1], 0);
    }

    /// An entrant who mints k times the supply takes k/(k+1) of the recovered component.
    function testFuzz_L03_captureIsKOverKPlusOne(uint256 k) public {
        k = bound(k, 1, 1000);
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt);
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 2e18 * k);
        entrant.bundle(vault, address(faulty), k * SHARE);
        faulty.setBlocked(address(vault), false);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        uint256[] memory got = entrant.redeemAll(vault);
        assertEq(got[0], 2e18 * k);
        assertEq(got[1], Math.mulDiv(5e18, k, k + 1));
    }

    /// Control: a pause before readyAt stops the bundle; the write-off can still be executed alone,
    /// and the sync returns all of F to Alice.
    function test_L03_controlPauseBeforeReadyAt() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt - 1);
        vm.prank(GOVERNANCE);
        vault.setMintPaused(true);
        vm.warp(readyAt);
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        vm.expectRevert(GRETVault.MintIsPaused.selector);
        entrant.bundle(vault, address(faulty), 9 * SHARE);
        vault.writeOffComponent(address(faulty)); // anyone, alone, while paused
        faulty.setBlocked(address(vault), false);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        vm.prank(ALICE);
        uint256[] memory alice = vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(alice[0], 2e18);
        assertEq(alice[1], 5e18);
    }

    /// Variant: F recovers after readyAt and governance's public cancelWriteOff is front-run.
    function test_L03_frontRunsCancelAfterRecovery() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt + 1 days);
        faulty.setBlocked(address(vault), false); // recovered; the write-off is still pending and ready
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        entrant.bundle(vault, address(faulty), 9 * SHARE); // lands before the cancel
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NoPendingWriteOff.selector, address(faulty)));
        vm.prank(GOVERNANCE);
        vault.cancelWriteOff(address(faulty));
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        uint256[] memory got = entrant.redeemAll(vault);
        assertEq(got[1], 45e17);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-L09: basketVersion bumps revert prepared redemptions during a notice
    // ---------------------------------------------------------------------------------------------

    function _announceJunk(uint256 n) internal returns (address[] memory junk) {
        junk = new address[](n);
        vm.startPrank(GOVERNANCE);
        for (uint256 i; i < n; ++i) {
            junk[i] = address(new Junk());
            vault.announceComponent(junk[i]);
        }
        vm.stopPrank();
    }

    function test_L09_versionBumpsRevertPreparedRedemptions() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        uint256 n = 10;
        address[] memory junk = _announceJunk(n);
        vm.warp(block.timestamp + 7 days);
        // The hostile notice starts: a rebalancer and a guard that accepts everything.
        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(new MockPriceGuard()));
        vm.stopPrank();

        // Without zero-reserve components there is no immediate bump (all 11 pilot components have reserves).
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(healthy), 4e18));
        vm.prank(GOVERNANCE);
        vault.removeComponent(address(healthy));

        uint256 reverted;
        for (uint256 k; k < 2 * n; ++k) {
            uint256 v = vault.basketVersion();
            uint256[] memory minOut = new uint256[](vault.componentCount());
            // Front-run: anyone adds a ready junk token, or governance removes one at once.
            if (k < n) {
                vault.addComponent(junk[k]);
            } else {
                vm.prank(GOVERNANCE);
                vault.removeComponent(junk[k - n]);
            }
            vm.prank(BOB);
            try vault.redeem(SHARE, minOut, v) {} catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(GRETVault.BasketChanged.selector, v, v + 1));
                ++reverted;
            }
            vm.roll(block.number + 1);
        }
        assertEq(reverted, 2 * n);
        // Bumps used up: the next prepared redemption goes through, still inside the notice.
        assertLt(block.timestamp, vault.pendingRebalancerReadyAt());
        uint256 current = vault.basketVersion();
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), current);
        assertEq(vault.balanceOf(BOB), 0);
    }

    /// Junk added inside its execution window can sit in the basket with no reserve and be removed
    /// at once at any later time, so the bump capacity can be stockpiled long before a notice.
    function test_L09_stockpiledJunkBumpsLongAfter() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        address[] memory junk = _announceJunk(3);
        Junk late = new Junk();
        vm.prank(GOVERNANCE);
        vault.announceComponent(address(late));
        vm.warp(block.timestamp + 7 days);
        for (uint256 i; i < 3; ++i) {
            vault.addComponent(junk[i]);
        }
        vm.warp(block.timestamp + 90 days);
        // Unadded announcements expire after their window; added junk does not.
        vm.expectRevert();
        vault.addComponent(address(late));
        uint256 v = vault.basketVersion();
        uint256[] memory minOut = new uint256[](vault.componentCount());
        vm.prank(GOVERNANCE);
        vault.removeComponent(junk[1]); // not the last index: also shifts junk[2]
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BasketChanged.selector, v, v + 1));
        vm.prank(BOB);
        vault.redeem(SHARE, minOut, v);
    }

    /// Mitigation check: a wallet that reads the version at execution is not affected by bumps in
    /// earlier transactions.
    function test_L09_walletReadingVersionAtExecutionIsImmune() public {
        VersionReadingWallet wallet = new VersionReadingWallet();
        healthy.mint(address(wallet), 2e18);
        faulty.mint(address(wallet), 5e18);
        wallet.mintBasket(vault, SHARE);
        address[] memory junk = _announceJunk(2);
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(junk[0]);
        vm.prank(GOVERNANCE);
        vault.removeComponent(junk[0]);
        uint256[] memory out = wallet.redeemNow(vault, SHARE);
        assertEq(out[0], 2e18);
        assertEq(out[1], 5e18);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-I02: redeem before a losing swap and mint after it
    // ---------------------------------------------------------------------------------------------

    function _gretValue(ChainlinkPriceGuard guard, uint256 shares) internal view returns (uint256) {
        uint256[] memory r = vault.reserves();
        uint256 nav = guard.valueOf(address(healthy), r[0]) + guard.valueOf(address(faulty), r[1]);
        return Math.mulDiv(nav, shares, vault.totalSupply());
    }

    function _wealth(ChainlinkPriceGuard guard, address account) internal view returns (uint256) {
        return guard.valueOf(address(healthy), healthy.balanceOf(account))
            + guard.valueOf(address(faulty), faulty.balanceOf(account)) + _gretValue(guard, vault.balanceOf(account));
    }

    /// Sells 1 H ($100) for 2.46 F ($98.40): a $1.60 loss, 1.6% of the value sold.
    function _losingSwap() internal {
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), 246e16);
    }

    function test_I02_swapLossSharedWithoutDodge() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 aliceBefore = _gretValue(guard, SHARE);
        uint256 bobBefore = _wealth(guard, BOB);
        _losingSwap();
        assertEq(aliceBefore - _gretValue(guard, SHARE), 8e17);
        assertEq(bobBefore - _wealth(guard, BOB), 8e17);
        assertEq(guard.weeklyLoss(), 2e15);
    }

    function test_I02_swapLossDodgedByRedeemThenMint() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 aliceBefore = _gretValue(guard, SHARE);
        uint256 bobBefore = _wealth(guard, BOB);
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), 0); // sees the swap coming
        _losingSwap();
        vm.prank(BOB);
        vault.mint(SHARE, _pair(type(uint256).max, type(uint256).max), SHARE, 0);
        assertEq(aliceBefore - _gretValue(guard, SHARE), 16e17);
        assertEq(_wealth(guard, BOB), bobBefore);
        assertEq(guard.weeklyLoss(), 4e15);
        assertEq(vault.balanceOf(BOB), SHARE);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-I03: LossRecognized names the component by index
    // ---------------------------------------------------------------------------------------------

    function test_I03_lossRecognizedIndexNamesAnotherTokenAfterRemoval() public {
        MockFaultyERC20 a = new MockFaultyERC20("A", "A", 18);
        MockFaultyERC20 b = new MockFaultyERC20("B", "B", 18);
        MockFaultyERC20 c = new MockFaultyERC20("C", "C", 18);
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = a;
        basket[1] = b;
        basket[2] = c;
        GRETVault v = new GRETVault(basket, _three(1e18, 1e18, 1e18), GOVERNANCE);
        a.mint(ALICE, 1e18);
        b.mint(ALICE, 1e18);
        c.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        a.approve(address(v), 1e18);
        b.approve(address(v), 1e18);
        c.approve(address(v), 1e18);
        v.mint(SHARE, _three(1e18, 1e18, 1e18), SHARE, 0);
        vm.stopPrank();

        // B loses 30%; anyone recognizes it.
        b.slash(address(v), 3e17);
        vm.recordLogs();
        v.recognizeLoss(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], GRETVault.LossRecognized.selector);
        assertEq(logs[0].topics.length, 2, "only the index is indexed");
        assertEq(uint256(logs[0].topics[1]), 1);
        assertEq(logs[0].data, abi.encode(uint256(3e17), uint256(7e17)), "no token address in the data");

        // In the same block A's whole reserve is gone (sold off or seized) and governance removes it.
        a.slash(address(v), 1e18);
        v.recognizeLoss(0);
        vm.prank(GOVERNANCE);
        v.removeComponent(address(a));

        // The component list at the end of that block maps index 1 to C, not to B.
        assertEq(address(v.components()[1]), address(c));
        assertEq(address(v.components()[0]), address(b));
        // B's 0.3 comes back: index 1 today has nothing to sync, B (now index 0) has it all.
        b.mint(address(v), 3e17);
        assertEq(v.componentSurplus(1), 0);
        assertEq(v.componentSurplus(0), 3e17);
        // Syncing by address is unambiguous.
        vm.prank(GOVERNANCE);
        assertEq(v.sync(address(b)), 3e17);
    }

    // ---------------------------------------------------------------------------------------------
    // REVIEW2-I05: the six proposal events and their readyAt
    // ---------------------------------------------------------------------------------------------

    function test_I05_proposalEventsCarryReadyAt() public {
        uint256 readyAt = block.timestamp + 7 days;
        MockPriceGuard guard = new MockPriceGuard();
        Junk token = new Junk();
        vm.startPrank(GOVERNANCE);
        vm.expectEmit(address(vault));
        emit GRETVault.RebalancerProposed(REBALANCER, readyAt);
        vault.proposeRebalancer(REBALANCER);
        vm.expectEmit(address(vault));
        emit GRETVault.PriceGuardProposed(address(guard), readyAt);
        vault.proposePriceGuard(address(guard));
        vm.expectEmit(address(vault));
        emit GRETVault.ComponentAnnounced(address(token), readyAt);
        vault.announceComponent(address(token));
        vm.expectEmit(address(vault));
        emit GRETVault.WriteOffProposed(address(faulty), readyAt);
        vault.proposeWriteOff(address(faulty));
        vault.setFeeRecipient(CAROL);
        vm.expectEmit(address(vault));
        emit GRETVault.FeesProposed(10, 20, readyAt);
        vault.proposeFees(10, 20);
        vm.expectEmit(address(vault));
        emit GRETVault.GovernanceProposed(CAROL, readyAt);
        vault.proposeGovernance(CAROL);
        vm.stopPrank();
    }
}
