// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {ChainlinkPriceGuard} from "../contracts/ChainlinkPriceGuard.sol";
import {GRETVaultCase, SenderSurchargeToken, NoOpTransferToken} from "./helpers/GRETVaultCase.sol";

/// @notice Known limitations (docs/SPECIFICATION.md): each test reproduces the accepted behavior;
/// change it if the decision changes.
contract GRETVaultLimitationsTest is GRETVaultCase {
    /// A donation obstructs retirement, but a transferable, tradable token can be sold.
    function test_donationBlocksRemovalUntilAnotherSale() public {
        _appoint(vault, address(new MockPriceGuard()));
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 2e18, address(faulty), 1);
        healthy.mint(address(vault), 11);
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(healthy), 11));
        vault.removeComponent(address(healthy));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(healthy), 11));
        vault.deactivateEmptyComponent(address(healthy));
        vm.stopPrank();
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 11, address(faulty), 1);
        vm.prank(GOVERNANCE);
        vault.removeComponent(address(healthy));
        assertEq(vault.componentCount(), 1);
    }

    /// The feed prices F's underlying at $40, but F itself trades at $0.40. Selling the whole
    /// H reserve for F at the feed price records no loss, so neither limit applies.
    function test_depegTheFeedDoesNotSeeIsNotLimited() public {
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

    /// A holder who never minted cannot leave while minting is paused, so a captured
    /// governance can pause, appoint a rebalancer and drain the vault after the notice.
    function test_pauseKeepsNonMinterInDuringNotice() public {
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

    /// A holder who never minted cannot qualify while a component cannot be paid in, so
    /// skipping it is not available to them either.
    function test_frozenComponentKeepsNonMinterFromQualifying() public {
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


    /// An entry before a future donation still shares that donation.
    function test_entryBeforeFutureDonationStillSharesIt() public {
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.mint(99 * SHARE, _pair(198e18, 495e18), 99 * SHARE, 0);
        healthy.mint(address(vault), 100e18);
        vm.prank(BOB);
        vault.redeem(99 * SHARE, _pair(0, 0), 0);
        assertEq(healthy.balanceOf(BOB) - before, 99e18);
    }

    /// The write-off pauses minting; if governance resumes it before reactivating the recovered
    /// balance, whoever mints in between takes most of it from the holders who bore the write-off.
    function test_mintResumedBeforeReactivationSharesRecovery() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnTransfer);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));
        assertTrue(vault.mintPaused());
        vm.prank(GOVERNANCE);
        vault.setMintPaused(false);

        healthy.mint(CAROL, 1e24);
        vm.startPrank(CAROL);
        healthy.approve(address(vault), type(uint256).max);
        vault.mint(9 * SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0); // pays no faulty at all
        vm.stopPrank();

        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(faulty));
        vm.prank(CAROL);
        vault.redeem(9 * SHARE, _pair(0, 0), 0);
        // 9 of 10 GRET: 90% of the 5 faulty that Alice held.
        assertEq(faulty.balanceOf(CAROL), 45e17);
        assertEq(healthy.balanceOf(CAROL), 1e24);
    }

    /// A tiny mint that cannot be redeemed alone keeps the supply under the 1 GRET floor if
    /// the last holder leaves.
    function test_tinyMintHoldsBackLastHolder() public {
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

    /// Fee GRET below 1 GRET held by the recipient keeps the last holder from leaving in full,
    /// even after both fees are cut to zero, until the recipient hands it over.
    function test_feeRecipientHoldsBackLastHolder() public {
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

    /// Redemption minima apply to the amounts sent, not to what arrives.
    function test_redeemMinimumIgnoresRecipientFee() public {
        faulty.setFault(MockFaultyERC20.Fault.FeeOnTransfer);
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256[] memory reported = vault.redeem(SHARE, _pair(2e18, 5e18), 0);
        assertEq(reported[1], 5e18);
        assertEq(faulty.balanceOf(ALICE) - before, 495e16);
        assertEq(vault.balanceOf(ALICE), 0);
    }

    /// A transfer that reports success without moving anything still consumes the claim.
    function test_noOpTransferStillConsumesClaim() public {
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
        assertEq(single.claimed(ALICE, 0), 100e18);
        assertEq(single.pendingRights(ALICE, 0), 50e18); // Undelivered tokens are automatically reallocated.
    }

    /// A surcharge the token takes from the sender comes out of the remaining holders'
    /// backing, unlike in a rescue.
    function test_senderSurchargeComesOutOfRemainingBacking() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        token.enable();
        vm.prank(ALICE);
        single.redeem(SHARE, _one(100e18), 0);
        assertEq(single.reserves()[0], 99e18);
        assertEq(token.balanceOf(address(single)), 99e18);
        // The last transfer now needs more than the entire balance.
        vm.expectRevert();
        vm.prank(BOB);
        single.redeem(SHARE, _one(0), 0);
        assertEq(single.balanceOf(BOB), SHARE);
    }

    /// Liquidation does not lift the sender surcharge's dead end for the last claimant.
    function test_senderSurchargeBlocksLastClaim() public {
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


    /// A small mint in front of a sale of the whole reserve leaves dust behind, which keeps
    /// the component from being removed.
    function test_mintBeforeWholeSaleLeavesDustThatBlocksRemoval() public {
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

    /// Rights converted separately cannot be pooled, so a balance where every payout rounds
    /// to zero stays in the vault.
    function test_payoutsThatRoundToZeroLeaveUnclaimableDust() public {
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
    }
}

/// @notice Late recoveries during liquidation are shared pro rata, not targeted to whoever took a
/// cut, and a removed component cannot rejoin the liquidation.
contract GRETVaultRecoveryLimitationsTest is GRETVaultCase {
    function _both() private {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        vm.prank(BOB);
        vault.convertToClaims(SHARE);
    }

    function test_automaticRecoveryIsNotTargetedCompensation() public {
        _both();
        uint256 aliceBefore = faulty.balanceOf(ALICE);
        uint256 bobBefore = faulty.balanceOf(BOB);
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        faulty.slash(address(vault), 2.5e18);
        vm.prank(BOB);
        assertEq(vault.claim(1, BOB, 0), 2.5e18);
        faulty.mint(address(vault), 2.5e18);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BackingToken.selector, address(faulty)));
        vm.prank(GOVERNANCE);
        vault.rescue(address(faulty), BOB, 2.5e18);
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        vm.prank(BOB);
        vault.claim(1, BOB, 0);
        assertEq(faulty.balanceOf(ALICE) - aliceBefore, 6.25e18);
        assertEq(faulty.balanceOf(BOB) - bobBefore, 3.75e18);
    }

    function testFuzz_recoveryRewardsPreviouslyPaidHolder(uint256 k, uint256 cutBps) public {
        k = bound(k, 1, 100);
        cutBps = bound(cutBps, 1, 9_999);
        vm.prank(BOB);
        vault.mint(k * SHARE, _pair(2e18 * k, 5e18 * k), k * SHARE, 0);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        vm.prank(BOB);
        vault.convertToClaims(k * SHARE);
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        uint256 loss = 5e18 * k * cutBps / 10_000;
        faulty.slash(address(vault), loss);
        vm.prank(BOB);
        uint256 early = vault.claim(1, BOB, 0);
        faulty.mint(address(vault), loss);
        vm.prank(ALICE);
        uint256 extra = vault.claim(1, ALICE, 0);
        vm.prank(BOB);
        uint256 recovered = vault.claim(1, BOB, 0);
        assertApproxEqAbs(extra, loss / (k + 1), 1);
        assertApproxEqAbs(5e18 * k - early - recovered, extra, 1);
        assertLe(faulty.balanceOf(address(vault)), 1);
    }

    function test_removedRecoveryCannotRejoinLiquidation() public {
        faulty.slash(address(vault), 5e18);
        vm.startPrank(GOVERNANCE);
        vault.removeComponent(address(faulty));
        vault.announceComponent(address(faulty));
        vault.activateLiquidation();
        vm.stopPrank();
        faulty.mint(address(vault), 5e18);
        vm.warp(vault.componentReadyAt(address(faulty)));
        vm.expectRevert(GRETVault.LiquidationIsActive.selector);
        vault.addComponent(address(faulty));
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(GOVERNANCE);
        vault.rescue(address(faulty), ALICE, 5e18);
        assertEq(faulty.balanceOf(ALICE) - before, 5e18);
    }
}
