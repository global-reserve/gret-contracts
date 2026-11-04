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
contract Junk {
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

contract GRETVaultGovernanceTest is GRETVaultCase {
    // ---------------------------------------------------------------------------------------------
    // A write-off pauses minting in the same transaction
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

    /// A contract cannot execute a ready write-off and mint without F in the same transaction, so
    /// nobody enters without paying for F and then shares its recovery.
    function test_writeOffPausesMintInSameTransaction() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt);
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        vm.expectRevert(GRETVault.MintIsPaused.selector);
        entrant.bundle(vault, address(faulty), 9 * SHARE);

        vm.expectEmit(address(vault));
        emit GRETVault.MintPauseChanged(true);
        vault.writeOffComponent(address(faulty)); // anyone, alone
        assertTrue(vault.mintPaused());

        // F recovers; governance reactivates it before resuming minting.
        faulty.setBlocked(address(vault), false);
        vm.startPrank(GOVERNANCE);
        vault.activateComponent(address(faulty));
        vault.setMintPaused(false);
        vm.stopPrank();
        vm.prank(ALICE);
        uint256[] memory alice = vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(alice[0], 2e18);
        assertEq(alice[1], 5e18);
    }

    /// A pause governance already set stays, without a second event.
    function test_writeOffKeepsAnExistingPauseWithoutEvent() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.prank(GOVERNANCE);
        vault.setMintPaused(true);
        vm.warp(readyAt);
        vm.recordLogs();
        vault.writeOffComponent(address(faulty));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != GRETVault.MintPauseChanged.selector, "second pause event");
        }
        assertTrue(vault.mintPaused());
    }

    /// Asking for the state the vault is already in changes nothing and emits nothing.
    function test_repeatedPauseAndActivationEmitNothing() public {
        vm.startPrank(GOVERNANCE);
        vault.setMintPaused(true);
        vm.recordLogs();
        vault.setMintPaused(true);
        vault.activateComponent(address(healthy));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(vault.mintPaused());
    }

    /// F recovers after readyAt, before governance cancels. A bundle of the ready write-off and a
    /// mint reverts as a whole, so the cancel still lands; executing the write-off alone only pauses
    /// minting until governance reactivates F, and later entrants pay for F.
    function test_recoveredComponentCannotBeCapturedBeforeCancel() public {
        uint256 readyAt = _freezeAndProposeWriteOff();
        vm.warp(readyAt + 1 days);
        faulty.setBlocked(address(vault), false); // recovered; the write-off is still pending and ready
        WriteOffBundler entrant = new WriteOffBundler();
        healthy.mint(address(entrant), 18e18);
        uint256 snapshot = vm.snapshotState();
        vm.expectRevert(GRETVault.MintIsPaused.selector);
        entrant.bundle(vault, address(faulty), 9 * SHARE);
        vm.prank(GOVERNANCE);
        vault.cancelWriteOff(address(faulty));
        assertFalse(vault.writtenOff(address(faulty)));
        assertFalse(vault.mintPaused());

        vm.revertToState(snapshot);
        vault.writeOffComponent(address(faulty));
        vm.startPrank(GOVERNANCE);
        vault.activateComponent(address(faulty));
        vault.setMintPaused(false);
        vm.stopPrank();
        vm.prank(BOB);
        (, uint256[] memory paid) = vault.mint(9 * SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        assertEq(paid[1], 45e18);
        vm.prank(ALICE);
        uint256[] memory alice = vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(alice[1], 5e18);
    }

    // ---------------------------------------------------------------------------------------------
    // basketVersion bumps revert prepared redemptions during a notice
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

    function test_versionBumpsRevertPreparedRedemptions() public {
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
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentNotEmpty.selector, address(healthy), 4e18));
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
        (, uint256 rebalancerReadyAt) = vault.rebalancerProposal();
        assertLt(block.timestamp, rebalancerReadyAt);
        uint256 current = vault.basketVersion();
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), current);
        assertEq(vault.balanceOf(BOB), 0);
    }

    /// Junk added inside its execution window can sit in the basket with no reserve and be removed
    /// at once at any later time, so the bump capacity can be stockpiled long before a notice.
    function test_stockpiledJunkBumpsLongAfter() public {
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
    function test_walletReadingVersionAtExecutionIsImmune() public {
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
    // Redeem before a losing swap and mint after it
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
        vault.swap(address(healthy), 1e18, address(faulty), 246e16, "");
    }

    function test_swapLossSharedWithoutDodge() public {
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

    function test_swapLossDodgedByRedeemThenMint() public {
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
    // Control: live balances follow addresses after an index shift
    // ---------------------------------------------------------------------------------------------

    function test_liveBalancesFollowComponentsAfterRemoval() public {
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

        b.slash(address(v), 3e17);
        assertEq(v.reserves()[1], 7e17);
        a.slash(address(v), 1e18);
        vm.prank(GOVERNANCE);
        v.removeComponent(address(a));
        assertEq(address(v.components()[0]), address(b));
        b.mint(address(v), 3e17);
        assertEq(v.reserves()[0], 1e18);
        assertEq(v.reserves()[1], 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // The six proposal events and their readyAt
    // ---------------------------------------------------------------------------------------------

    function test_proposalEventsCarryReadyAt() public {
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
