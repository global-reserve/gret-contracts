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

/// @notice Accepted recovery risks R-04 and R-25 in docs/ACCEPTED_RISKS.md.
/// @dev Governance is an ordinary EOA. Mock faults model possible issuer events, not observed
/// behavior of a pilot token. Production contracts are unchanged.
contract GRETVaultRecoveryRisksTest is GRETVaultCase {
    function _writeOff() private {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnTransfer);
        vm.startPrank(GOVERNANCE);
        vault.setMintPaused(true);
        vault.proposeWriteOff(address(faulty));
        vm.stopPrank();
        vm.warp(vault.writeOffReadyAt(address(faulty)));
        vault.writeOffComponent(address(faulty));
    }

    function _twoHolders() private {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
    }

    function _liquidateAndConvertBoth() private {
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        vm.prank(BOB);
        vault.convertToClaims(SHARE);
    }

    /// A former write-off remains non-rescuable after a full recovery. Direct reimbursement
    /// reverts even with sufficient surplus; P-2 therefore requires external settlement.
    function test_R04_writtenOffRecoveryCannotReimburseHaircut() public {
        _twoHolders();
        _writeOff();
        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        assertEq(vault.reserves()[1], 10e18);
        _liquidateAndConvertBoth();

        uint256 aliceBefore = faulty.balanceOf(ALICE);
        uint256 bobBefore = faulty.balanceOf(BOB);
        faulty.slash(address(vault), 5e18);
        vm.prank(ALICE);
        assertEq(vault.claim(1, ALICE, 0), 2.5e18);
        faulty.mint(address(vault), 5e18);
        assertEq(vault.componentSurplus(1), 2.5e18);

        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.TokenWrittenOff.selector, address(faulty)));
        vault.rescue(address(faulty), ALICE, 2.5e18);
        vault.sync(address(faulty));
        vm.stopPrank();
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        vm.prank(BOB);
        vault.claim(1, BOB, 0);

        assertEq(faulty.balanceOf(ALICE) - aliceBefore, 3.75e18);
        assertEq(faulty.balanceOf(BOB) - bobBefore, 6.25e18);
        assertEq(faulty.balanceOf(address(vault)), 0);
    }

    /// Control: the very same shortfall/recovery is settled exactly by P-2 without a write-off.
    function test_R04_controlOrdinaryComponentCanReimburseHaircut() public {
        _twoHolders();
        _liquidateAndConvertBoth();
        uint256 aliceBefore = faulty.balanceOf(ALICE);
        uint256 bobBefore = faulty.balanceOf(BOB);
        faulty.slash(address(vault), 5e18);
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        faulty.mint(address(vault), 5e18);
        vm.prank(GOVERNANCE);
        vault.rescue(address(faulty), ALICE, 2.5e18);
        vm.prank(BOB);
        vault.claim(1, BOB, 0);
        assertEq(faulty.balanceOf(ALICE) - aliceBefore, 5e18);
        assertEq(faulty.balanceOf(BOB) - bobBefore, 5e18);
    }

    /// Vary both holder concentration and the loss. Restoring the entire token balance still
    /// does not restore the early claimant; the shortfall is transferred to the waiting holder.
    function testFuzz_R04_syncTransfersPartOfCompensationToWaitingHolder(uint256 k, uint256 cutBps)
        public
    {
        k = bound(k, 1, 100);
        cutBps = bound(cutBps, 1, 9_999);
        vm.prank(BOB);
        vault.mint(k * SHARE, _pair(2e18 * k, 5e18 * k), k * SHARE, 0);
        _writeOff();
        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        vm.prank(BOB);
        vault.convertToClaims(k * SHARE);

        uint256 loss = 5e18 * (k + 1) * cutBps / 10_000;
        uint256 aliceBefore = faulty.balanceOf(ALICE);
        uint256 bobBefore = faulty.balanceOf(BOB);
        faulty.slash(address(vault), loss);
        vm.prank(ALICE);
        uint256 paidEarly = vault.claim(1, ALICE, 0);
        uint256 haircut = 5e18 - paidEarly;
        faulty.mint(address(vault), loss);
        assertEq(vault.componentSurplus(1), haircut);
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.TokenWrittenOff.selector, address(faulty)));
        vault.rescue(address(faulty), ALICE, haircut);
        vault.sync(address(faulty));
        vm.stopPrank();
        vm.prank(ALICE);
        vault.claim(1, ALICE, 0);
        vm.prank(BOB);
        vault.claim(1, BOB, 0);
        uint256 missing = 5e18 - (faulty.balanceOf(ALICE) - aliceBefore);
        uint256 extra = faulty.balanceOf(BOB) - bobBefore - 5e18 * k;
        assertGt(missing, 0);
        assertGt(extra, 0);
        assertApproxEqAbs(missing, Math.mulDiv(haircut, k, k + 1), 1);
        assertApproxEqAbs(extra, missing, 1);
        assertLe(faulty.balanceOf(address(vault)), 1);
    }

    /// Liquidating an empty supply permanently removes every vault exit for a written-off token.
    /// The last redemption may land immediately before an already prepared activation.
    function test_R25_emptyLiquidationStrandsWrittenOffRecovery() public {
        _writeOff();
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        assertEq(vault.liquidationSupply(), 0);

        faulty.setFault(MockFaultyERC20.Fault.None);
        assertEq(faulty.balanceOf(address(vault)), 5e18);
        assertEq(vault.componentSurplus(1), 5e18);
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(GRETVault.NoSupply.selector);
        vault.sync(address(faulty));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.TokenWrittenOff.selector, address(faulty)));
        vault.rescue(address(faulty), ALICE, 5e18);
        vm.expectRevert(GRETVault.LiquidationIsActive.selector);
        vault.removeComponent(address(faulty));
        vault.setMintPaused(false);
        vault.setInitialAmounts(_pair(2e18, 0), 0);
        vm.stopPrank();
        vm.startPrank(ALICE);
        vm.expectRevert(GRETVault.LiquidationIsActive.selector);
        vault.mint(SHARE, _pair(2e18, 0), SHARE, 0);
        vm.expectRevert();
        vault.convertToClaims(SHARE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NothingToClaim.selector, ALICE, 1));
        vault.claim(1, ALICE, 0);
        vm.stopPrank();
        assertEq(faulty.balanceOf(address(vault)), 5e18);
    }

    /// Control: activating before the last exit preserves rights even for a written-off token.
    function test_R25_controlLiveSupplyPreservesWrittenOffRecovery() public {
        _writeOff();
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        vm.prank(ALICE);
        assertEq(vault.claim(1, ALICE, 5e18), 5e18);
    }

    /// Control: with no liquidation, an empty vault can restart and allocate the recovery.
    function test_R25_controlEmptyNormalVaultCanRestart() public {
        _writeOff();
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        vm.prank(GOVERNANCE);
        vault.setMintPaused(false);
        vm.prank(ALICE);
        vault.mint(SHARE, _pair(2e18, 0), SHARE, 0);
        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        vm.prank(ALICE);
        uint256[] memory paid = vault.redeem(SHARE, _pair(2e18, 5e18), 0);
        assertEq(paid[1], 5e18);
    }

    /// Control: an empty liquidation does not trap ordinary (never written-off) surplus.
    function test_R25_controlEmptyLiquidationCanRescueOrdinarySurplus() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnTransfer);
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.prank(ALICE);
        vault.redeemSkipping(SHARE, _pair(0, 0), skipped, 0);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        faulty.setFault(MockFaultyERC20.Fault.None);
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(GOVERNANCE);
        vault.rescue(address(faulty), ALICE, 5e18);
        assertEq(faulty.balanceOf(ALICE) - before, 5e18);
    }

    /// P-7's re-add-and-sync procedure cannot operate after liquidation, even if a re-addition
    /// was announced before activation. External rescue and allocation remain possible.
    function test_R04_removedRecoveryCannotRejoinLiquidation() public {
        faulty.slash(address(vault), 5e18);
        vault.recognizeLoss(1);
        vm.startPrank(GOVERNANCE);
        vault.removeComponent(address(faulty));
        vault.announceComponent(address(faulty));
        vault.activateLiquidation();
        vm.stopPrank();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        faulty.mint(address(vault), 5e18);
        vm.warp(vault.componentReadyAt(address(faulty)));
        vm.expectRevert(GRETVault.LiquidationIsActive.selector);
        vault.addComponent(address(faulty));
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotAComponent.selector, address(faulty)));
        vault.sync(address(faulty));
        uint256 before = faulty.balanceOf(ALICE);
        vault.rescue(address(faulty), ALICE, 5e18);
        vm.stopPrank();
        assertEq(faulty.balanceOf(ALICE) - before, 5e18);
    }
}
