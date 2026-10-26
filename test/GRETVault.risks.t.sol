// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {ChainlinkPriceGuard} from "../contracts/ChainlinkPriceGuard.sol";
import {GRETVaultCase, SenderSurchargeToken, NoOpTransferToken} from "./helpers/GRETVaultCase.sol";

/// @notice Accepted risks (docs/ACCEPTED_RISKS.md): each test reproduces the accepted behavior,
/// named after its risk; change it if the decision changes.
contract GRETVaultRisksTest is GRETVaultCase {
    /// R-03: the feed prices F's underlying at $40, but F itself trades at $0.40. Selling the whole
    /// H reserve for F at the feed price records no loss, so neither limit applies.
    function test_R03_depegTheFeedDoesNotSeeIsNotLimited() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 marketPrice = 0.4e18;
        uint256 marketBefore = 2 * 100e18 + 5 * marketPrice;
        vm.recordLogs();
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 2e18, address(faulty), 5e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], ChainlinkPriceGuard.LossRecorded.selector);
        }
        assertEq(guard.weeklyLoss(), 0);
        assertEq(vault.reserves()[0], 0);
        uint256 marketAfter = vault.reserves()[1] * marketPrice / 1e18;
        assertEq(marketAfter, 4e18);
        assertGt(marketBefore - marketAfter, marketBefore * 98 / 100);
    }

    /// R-07: a holder who never minted cannot leave while minting is paused, so a captured
    /// governance can pause, appoint a rebalancer and drain the vault after the notice.
    function test_R07_pauseKeepsNonMinterInDuringNotice() public {
        vm.prank(ALICE);
        vault.transfer(BOB, SHARE);
        vm.startPrank(GOVERNANCE);
        vault.setMintPaused(true);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(new MockPriceGuard()));
        vm.stopPrank();
        assertFalse(vault.hasMinted(BOB));

        vm.startPrank(BOB);
        vm.expectRevert(GRETVault.MintIsPaused.selector);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.RedemptionNotEnabled.selector, BOB));
        vault.redeem(SHARE, _pair(0, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.RedemptionNotEnabled.selector, BOB));
        vault.redeemSkipping(SHARE, _pair(0, 0), new address[](0), 0);
        vm.expectRevert(GRETVault.LiquidationNotActive.selector);
        vault.convertToClaims(SHARE);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
        vm.startPrank(REBALANCER);
        vault.swap(address(healthy), 2e18, address(faulty), 1);
        vault.swap(address(faulty), 5e18 + 1, address(healthy), 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(BOB), SHARE);
        assertEq(healthy.balanceOf(address(vault)), 1);
        assertEq(faulty.balanceOf(address(vault)), 0);
    }

    /// R-07: a holder who never minted cannot qualify while a component cannot be paid in, so
    /// skipping it is not available to them either.
    function test_R07_frozenComponentKeepsNonMinterFromQualifying() public {
        vm.prank(ALICE);
        vault.transfer(BOB, SHARE / 2);
        faulty.setBlocked(address(vault), true);
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(MockFaultyERC20.AccountBlocked.selector, address(vault)));
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.RedemptionNotEnabled.selector, BOB));
        vault.redeemSkipping(SHARE / 2, _pair(0, 0), skipped, 0);
        vm.stopPrank();
    }

    /// R-08: whoever mints right before a sync takes their share of the synced balance.
    function test_R08_minterCapturesMostOfASync() public {
        healthy.mint(address(vault), 100e18);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.mint(99 * SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.prank(GOVERNANCE);
        vault.sync(address(healthy));
        vm.prank(BOB);
        vault.redeem(99 * SHARE, _pair(0, 0), 0);
        assertEq(healthy.balanceOf(BOB) - before, 99e18);
        assertEq(vault.reserves()[0], 3e18);
    }

    /// R-08: pausing minting inside the sync transaction does not undo an entry made before it.
    function test_R08_pauseAroundSyncDoesNotStopEarlierEntrant() public {
        healthy.mint(address(vault), 100e18);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.mint(99 * SHARE, _pair(198e18, 495e18), 99 * SHARE, 0);
        vm.startPrank(GOVERNANCE);
        vault.setMintPaused(true);
        vault.sync(address(healthy));
        vault.setMintPaused(false);
        vm.stopPrank();
        vm.prank(BOB);
        vault.redeem(99 * SHARE, _pair(0, 0), 0);
        assertEq(healthy.balanceOf(BOB) - before, 99e18);
        assertEq(vault.reserves()[0], 3e18);
    }

    /// R-08: whoever mints between a write-off and the sync of the recovered balance takes most of
    /// it from the holders who bore the write-off.
    function test_R08_lateMinterCapturesWriteOffRecovery() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnTransfer);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));

        healthy.mint(CAROL, 1e24);
        vm.startPrank(CAROL);
        healthy.approve(address(vault), type(uint256).max);
        vault.mint(9 * SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0); // pays no faulty at all
        vm.stopPrank();

        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        vm.prank(CAROL);
        vault.redeem(9 * SHARE, _pair(0, 0), 0);
        // 9 of 10 GRET: 90% of the 5 faulty that Alice held.
        assertEq(faulty.balanceOf(CAROL), 45e17);
        assertEq(healthy.balanceOf(CAROL), 1e24);
    }

    /// R-09: a tiny mint that cannot be redeemed alone keeps the supply under the 1 GRET floor if
    /// the last holder leaves.
    function test_R09_tinyMintHoldsBackLastHolder() public {
        // Still works when an incoming component loses one base unit.
        faulty.setFault(MockFaultyERC20.Fault.ShortByOneOnTransfer);
        vm.prank(BOB);
        (uint256 dust,) = vault.mint(1e12, _pair(type(uint256).max, type(uint256).max), 0, 0);
        assertGt(dust, 0);
        assertLt(dust, SHARE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, dust));
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);

        // Alice can redeem only the tiny excess over MIN_SUPPLY without cooperation.
        vm.prank(ALICE);
        vault.redeem(dust, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), SHARE);
        assertEq(vault.balanceOf(ALICE), SHARE - dust);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, SHARE - dust));
        vm.prank(ALICE);
        vault.redeem(dust, _pair(0, 0), 0);
    }

    /// R-09: fee GRET below 1 GRET held by the recipient keeps the last holder from leaving in full,
    /// even after both fees are cut to zero, until the recipient hands it over.
    function test_R09_feeRecipientHoldsBackLastHolder() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        vm.startPrank(GOVERNANCE);
        vault.setFeeRecipient(CAROL);
        vault.proposeFees(0, 500);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vault.applyFees();
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        vm.prank(GOVERNANCE);
        vault.proposeFees(0, 0);

        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, 5e16));
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), 0);
        vm.prank(CAROL);
        vault.transfer(BOB, 5e16);
        vm.prank(BOB);
        vault.redeem(SHARE + 5e16, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0);
    }

    /// R-10: redemption minima apply to the amounts sent, not to what arrives.
    function test_R10_redeemMinimumIgnoresRecipientFee() public {
        faulty.setFault(MockFaultyERC20.Fault.FeeOnTransfer);
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256[] memory reported = vault.redeem(SHARE, _pair(2e18, 5e18), 0);
        assertEq(reported[1], 5e18);
        assertEq(faulty.balanceOf(ALICE) - before, 495e16);
        assertEq(vault.balanceOf(ALICE), 0);
    }

    /// R-10: a transfer that reports success without moving anything still consumes the claim.
    function test_R10_noOpTransferStillConsumesClaim() public {
        NoOpTransferToken token = new NoOpTransferToken();
        GRETVault single = _single(token, 100e18);
        vm.prank(GOVERNANCE);
        single.activateLiquidation();
        vm.prank(ALICE);
        single.convertToClaims(SHARE);
        token.enable();
        vm.prank(ALICE);
        assertEq(single.claim(0, ALICE, 100e18), 100e18);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(single.pendingRights(ALICE, 0), 0);
        assertEq(single.componentSurplus(0), 100e18);
    }

    /// R-13: a surcharge the token takes from the sender comes out of the remaining holders'
    /// backing, unlike in a rescue.
    function test_R13_senderSurchargeComesOutOfRemainingBacking() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        token.enable();
        vm.prank(ALICE);
        single.redeem(SHARE, _one(100e18), 0);
        assertEq(single.reserves()[0], 100e18);
        assertEq(token.balanceOf(address(single)), 99e18);
        assertEq(single.recognizeLoss(0), 1e18);
        // The last transfer now needs more than the entire balance.
        vm.expectRevert();
        vm.prank(BOB);
        single.redeem(SHARE, _one(0), 0);
        assertEq(single.balanceOf(BOB), SHARE);
    }

    /// R-13: liquidation does not lift the sender surcharge's dead end for the last claimant.
    function test_R13_senderSurchargeBlocksLastClaim() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        vm.prank(GOVERNANCE);
        single.activateLiquidation();
        vm.prank(ALICE);
        single.convertToClaims(SHARE);
        vm.prank(BOB);
        single.convertToClaims(SHARE);
        token.enable();
        vm.prank(ALICE);
        assertEq(single.claim(0, ALICE, 100e18), 100e18);
        assertEq(single.claimable(BOB, 0), 99e18);
        vm.expectRevert();
        vm.prank(BOB);
        single.claim(0, BOB, 0);
        assertEq(single.pendingRights(BOB, 0), 100e18);
        assertEq(token.balanceOf(address(single)), 99e18);
    }

    /// R-14: when a component's balance cannot be read, the first redeemer is paid in full and
    /// the loss falls on whoever comes after.
    function test_R14_brokenBalanceReadPaysFirstRedeemerInFull() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        faulty.slash(address(vault), 5e18);
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(faulty.rawBalanceOf(address(vault)), 0);
        vm.expectRevert();
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), 0);
    }

    /// R-16: a small mint in front of a sale of the whole reserve leaves dust behind, which keeps
    /// the component from being removed.
    function test_R16_mintBeforeWholeSaleLeavesDustThatBlocksRemoval() public {
        _appoint(vault, address(new MockPriceGuard()));
        uint256 whole = vault.reserves()[0];
        vm.prank(BOB);
        vault.mint(1e9, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), whole, address(faulty), 1);
        assertGt(vault.reserves()[0], 0);
        vm.expectRevert(
            abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(healthy), vault.reserves()[0])
        );
        vm.prank(GOVERNANCE);
        vault.removeComponent(address(healthy));
    }

    /// R-21: rights converted separately cannot be pooled, so a balance where every payout rounds
    /// to zero stays in the vault.
    function test_R21_payoutsThatRoundToZeroLeaveUnclaimableDust() public {
        MockFaultyERC20 token = new MockFaultyERC20("Indivisible", "I", 0);
        IERC20[] memory basket = new IERC20[](1);
        basket[0] = token;
        GRETVault single = new GRETVault(basket, _one(1), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : BOB;
            token.mint(user, 1);
            vm.startPrank(user);
            token.approve(address(single), 1);
            single.mint(SHARE, _one(1), SHARE, 0);
            vm.stopPrank();
        }
        vm.prank(GOVERNANCE);
        single.activateLiquidation();
        vm.prank(ALICE);
        single.convertToClaims(SHARE);
        vm.prank(BOB);
        single.convertToClaims(SHARE);
        token.slash(address(single), 1);
        assertEq(single.claimable(ALICE, 0), 0);
        assertEq(single.claimable(BOB, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NothingToClaim.selector, ALICE, 0));
        vm.prank(ALICE);
        single.claim(0, ALICE, 0);
        assertEq(token.balanceOf(address(single)), 1);
        assertEq(single.componentSurplus(0), 0);
    }
}
