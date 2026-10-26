// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {GRETVaultCase, SenderSurchargeToken, GasBurnerToken} from "./helpers/GRETVaultCase.sol";

/// @notice Protections: each test plays an attack or a failure and shows what the vault refuses
/// or lets holders do about it.
contract GRETVaultProtectionsTest is GRETVaultCase {
    /// `minAmount` lets the claimant refuse an unexpected cut and keep the right pending.
    function test_claimMinimumRefusesUnexpectedCut() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        assertEq(vault.claimable(ALICE, 1), 5e18);

        // Models an issuer loss between a wallet quote and transaction inclusion.
        faulty.slash(address(vault), 9e18);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.AmountOutBelowMin.selector, 1, 5e17, 49e17));
        vm.prank(ALICE);
        vault.claim(1, ALICE, 49e17);
        assertEq(vault.pendingRights(ALICE, 1), 5e18);

        // Once the balance recovers, the same protected claim pays the whole right.
        faulty.mint(address(vault), 9e18);
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(ALICE);
        assertEq(vault.claim(1, ALICE, 49e17), 5e18);
        assertEq(faulty.balanceOf(ALICE) - before, 5e18);
    }

    /// `minShares` lets the minter refuse a mint that would overcontribute healthy components.
    function test_minSharesRefusesShortfallAfterSevereLoss() public {
        faulty.slash(address(vault), 5e18 - 11);
        faulty.setFault(MockFaultyERC20.Fault.ShortByOneOnTransfer);
        uint256 before = healthy.balanceOf(BOB);
        uint256 minShares = SHARE - SHARE / 1000;
        // One base unit of F short issues only 10/11 of a share, below the minimum: nothing moves.
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SharesBelowMin.selector, 10 * SHARE / 11, minShares));
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 11), minShares, 0);
        assertEq(healthy.balanceOf(BOB), before);
        assertEq(vault.balanceOf(BOB), 0);
    }

    /// Mint does not ask for a component with no reserve, so a new holder qualifies for redemption
    /// with the healthy components alone and exits without liquidation.
    function test_newHolderQualifiesAfterTotalLoss() public {
        vm.prank(ALICE);
        vault.transfer(BOB, SHARE);
        faulty.slash(address(vault), 5e18);
        vault.recognizeLoss(1);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.RedemptionNotEnabled.selector, BOB));
        vm.prank(BOB);
        vault.redeem(SHARE, _pair(0, 0), 0);

        uint256 before = healthy.balanceOf(BOB);
        vm.startPrank(BOB);
        (uint256 minted, uint256[] memory paid) = vault.mint(SHARE, _pair(type(uint256).max, 0), 0, 0);
        assertEq(minted, SHARE);
        assertEq(paid[1], 0);
        vault.redeem(2 * SHARE, _pair(0, 0), 0);
        vm.stopPrank();
        assertEq(healthy.balanceOf(BOB), before + 2e18);
        assertEq(vault.totalSupply(), 0);
    }

    /// A rescue that would leave less than what is owed reverts.
    function test_rescueCannotReduceBackingThroughSenderFee() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        token.mint(address(single), 1e18);
        token.enable();
        // The 1% sender debit would leave 199.99 behind 200 owed.
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BackingReduced.selector, address(token), 19999e16, 200e18));
        vm.prank(GOVERNANCE);
        single.rescue(address(token), CAROL, 1e18);
        assertEq(token.balanceOf(address(single)), 201e18);
        assertEq(token.balanceOf(CAROL), 0);
    }

    /// Syncing a component the vault cannot send blocks `redeem`, but `redeemSkipping` lets holders
    /// leave with the other components during the seven-day notice of a new rebalancer.
    function test_holdersExitDuringRebalancerNoticeBySkipping() public {
        vm.prank(BOB);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        faulty.setBlocked(address(vault), true);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));

        // A captured governance syncs the frozen balance back and appoints its rebalancer.
        vm.startPrank(GOVERNANCE);
        assertEq(vault.sync(address(faulty)), 10e18);
        vault.proposeRebalancer(REBALANCER);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MockFaultyERC20.AccountBlocked.selector, address(vault)));
        vm.prank(BOB);
        vault.redeem(SHARE / 4, _pair(0, 0), 0);

        // During the notice, Bob leaves with his share of everything that still moves.
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.redeemSkipping(SHARE / 4, _pair(0, 0), skipped, 0);
        assertEq(healthy.balanceOf(BOB) - before, 5e17);
    }

    /// A skipped component is never called, so even a token that burns all the gas in `balanceOf`
    /// and `transfer` cannot block the exit.
    function test_skippedComponentIsNeverCalled() public {
        GasBurnerToken burner = new GasBurnerToken();
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy;
        basket[1] = burner;
        GRETVault target = new GRETVault(basket, _pair(2e18, 1e18), GOVERNANCE);
        burner.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        healthy.approve(address(target), type(uint256).max);
        burner.approve(address(target), type(uint256).max);
        target.mint(SHARE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.stopPrank();

        burner.enable();
        vm.expectRevert();
        vm.prank(ALICE);
        target.redeem{gas: 5_000_000}(SHARE, _pair(0, 0), 0);

        address[] memory skipped = new address[](1);
        skipped[0] = address(burner);
        uint256 before = healthy.balanceOf(ALICE);
        vm.prank(ALICE);
        target.redeemSkipping{gas: 5_000_000}(SHARE, _pair(0, 0), skipped, 0);
        assertEq(healthy.balanceOf(ALICE) - before, 2e18);
    }

    /// A written-off component cannot be removed, so there is never a seven-day re-announcement to
    /// exploit, and a recovery during liquidation is synced at once.
    function test_writtenOffComponentStaysAndRecoversDuringLiquidation() public {
        faulty.setBlocked(address(vault), true);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vm.prank(CAROL);
        vault.writeOffComponent(address(faulty));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.TokenWrittenOff.selector, address(faulty)));
        vm.prank(GOVERNANCE);
        vault.removeComponent(address(faulty));

        // Liquidation starts right after the write-off: the rights over the component start at zero.
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.prank(ALICE);
        vault.convertToClaims(SHARE);
        assertEq(vault.pendingRights(ALICE, 1), 0);

        // The issuer lifts the freeze: sync restores every holder's rights.
        faulty.setBlocked(address(vault), false);
        vm.prank(GOVERNANCE);
        vault.sync(address(faulty));
        assertEq(vault.pendingRights(ALICE, 1), 5e18);
        vm.prank(ALICE);
        assertEq(vault.claim(1, ALICE, 0), 5e18);
    }

    /// A ready proposal expires after `EXECUTION_WINDOW`, and revoking the rebalancer also discards
    /// a pending one.
    function test_proposalsExpireAndRevokeClearsPending() public {
        MockERC20 extra = new MockERC20("Extra", "X", 18);
        vm.startPrank(GOVERNANCE);
        vault.announceComponent(address(extra));
        vault.setFeeRecipient(CAROL);
        vault.proposeFees(500, 500);
        vault.proposeRebalancer(REBALANCER);
        vault.revokeRebalancer();
        vm.stopPrank();
        uint256 expiredAt = block.timestamp + vault.BASKET_CHANGE_DELAY() + vault.EXECUTION_WINDOW();

        vm.warp(block.timestamp + 365 days);
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ProposalExpired.selector, expiredAt));
        vault.addComponent(address(extra));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ProposalExpired.selector, expiredAt));
        vault.applyFees();
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotPendingRebalancer.selector, REBALANCER));
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        assertEq(vault.componentCount(), 2);
        assertEq(vault.mintFee(), 0);
        assertEq(vault.rebalancer(), address(0));
    }

    /// With the Chainlink price guard, a stolen rebalancer key cannot sell a reserve for 1 wei, and
    /// swaps that each lose less than 2% stop once they have taken 2% of the vault's value in the
    /// week. H is worth $100 and F $40, so the vault holds $400.
    function test_priceGuardStopsRebalancerDrain() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        vm.startPrank(REBALANCER);
        // $200 of H for 1 wei of F.
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceGuard.SwapLossTooHigh.selector, 200e18, 40));
        vault.swap(address(healthy), 2e18, address(faulty), 1);
        // Each swap loses $1.90, 1.9% of the $100 it sells and about 0.48% of the vault.
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18);
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18);
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18);
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18);
        vm.expectPartialRevert(ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18);
        vm.stopPrank();
        uint256 expected;
        uint256 value = 400e18;
        for (uint256 i; i < 4; ++i) {
            expected += Math.mulDiv(1.9e18, 1e18, value, Math.Rounding.Ceil);
            value -= 1.9e18;
        }
        assertEq(guard.weeklyLoss(), expected);
        assertEq(_aliceValue(guard), 392.4e18);
    }

    /// Capital that is in the vault only while the week's first loss is recorded does not stretch
    /// the limit: each loss counts against the vault's value at that moment.
    function test_priceGuardLimitHoldsAfterTemporaryDeposit() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 before = _aliceValue(guard);
        vm.startPrank(REBALANCER);
        vault.mint(99 * SHARE, _pair(198e18, 495e18), 99 * SHARE, 0);
        // With $40,000 in the vault, a swap that loses $0.10.
        vault.swap(address(healthy), 1e18, address(faulty), 2.4975e18);
        vault.redeem(99 * SHARE, _pair(0, 0), 0);
        vm.stopPrank();
        assertLe(_lossySwapsUntilRefused(guard), 2);
        assertGe(_aliceValue(guard), before * 98 / 100);
    }

    /// The same after an ordinary large exit: the limit shrinks with what is left.
    function test_priceGuardLimitShrinksWithRedemptions() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 before = _aliceValue(guard);
        vm.prank(BOB);
        vault.mint(99 * SHARE, _pair(198e18, 495e18), 99 * SHARE, 0);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), 2.4975e18);
        vm.prank(BOB);
        vault.redeem(99 * SHARE, _pair(0, 0), 0);
        assertLe(_lossySwapsUntilRefused(guard), 2);
        assertGe(_aliceValue(guard), before * 98 / 100);
    }

    /// A balance the vault no longer holds does not stretch the limit, even if nobody has
    /// recognized its loss yet. Healthy H and O are worth $100 each and F $19,800, all at $1;
    /// F's issuer then takes the whole F balance.
    function test_priceGuardIgnoresBalanceTheVaultNoLongerHolds() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = healthy;
        basket[1] = other;
        basket[2] = faulty;
        uint256[] memory initial = _three(100e18, 100e18, 19_800e18);
        GRETVault target = new GRETVault(basket, initial, GOVERNANCE);
        other.mint(ALICE, 100e18);
        other.mint(REBALANCER, 1e24);
        vm.startPrank(ALICE);
        healthy.approve(address(target), type(uint256).max);
        other.approve(address(target), type(uint256).max);
        faulty.approve(address(target), type(uint256).max);
        target.mint(SHARE, initial, SHARE, 0);
        vm.stopPrank();
        vm.startPrank(REBALANCER);
        healthy.approve(address(target), type(uint256).max);
        other.approve(address(target), type(uint256).max);
        vm.stopPrank();
        MockAggregator feed = new MockAggregator(8, 1e8);
        address[] memory tokens = new address[](3);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](3);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = address(basket[i]);
            feeds[i] = IChainlinkFeed(address(feed));
        }
        ChainlinkPriceGuard guard =
            new ChainlinkPriceGuard(address(target), tokens, feeds, _three(1 days, 1 days, 1 days));
        _appoint(target, address(guard));
        feed.setAnswer(1e8);
        faulty.slash(address(target), 19_800e18);
        assertEq(target.reserves()[2], 19_800e18);

        // Each swap sells a whole healthy reserve for 98% of its value. The first takes 1% of the
        // $200 left; the second would take 2% more.
        vm.startPrank(REBALANCER);
        target.swap(address(healthy), 100e18, address(other), 98e18);
        vm.expectPartialRevert(ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
        target.swap(address(other), 198e18, address(healthy), 194.04e18);
        vm.stopPrank();
        assertEq(guard.weeklyLoss(), 1e16);
        assertEq(healthy.balanceOf(address(target)) + other.balanceOf(address(target)), 198e18);
    }

    /// Minima are prepared for a basket version, so after an equal-length basket replacement they
    /// cannot attach to a different token.
    function test_minimaPreparedForAnotherBasketAreRefused() public {
        MockERC20 first = new MockERC20("First", "A", 18);
        MockFaultyERC20 protectedToken = new MockFaultyERC20("Protected", "B", 18);
        MockERC20 last = new MockERC20("Last", "C", 18);
        MockERC20 extra = new MockERC20("Extra", "D", 18);
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = first;
        basket[1] = protectedToken;
        basket[2] = last;
        uint256[] memory initial = _three(1e18, 100e18, 100e18);
        GRETVault target = new GRETVault(basket, initial, GOVERNANCE);
        for (uint256 k; k < 2; ++k) {
            address user = k == 0 ? ALICE : BOB;
            first.mint(user, 1e18);
            protectedToken.mint(user, 100e18);
            last.mint(user, 100e18);
            vm.startPrank(user);
            first.approve(address(target), 1e18);
            protectedToken.approve(address(target), 100e18);
            last.approve(address(target), 100e18);
            target.mint(SHARE, initial, SHARE, 0);
            vm.stopPrank();
        }
        vm.prank(GOVERNANCE);
        target.announceComponent(address(extra));
        _appoint(target, address(new MockPriceGuard()));
        last.mint(REBALANCER, 2e18);
        vm.startPrank(REBALANCER);
        last.approve(address(target), 2e18);
        target.swap(address(first), 2e18, address(last), 2e18);
        vm.stopPrank();
        // Alice signs against [A, B, C], explicitly requiring 100 B.
        uint256[] memory signedMinima = _three(0, 100e18, 0);
        uint256 signedVersion = target.basketVersion();
        vm.prank(GOVERNANCE);
        target.removeComponent(address(first));
        target.addComponent(address(extra)); // [B, C, D], still length three
        protectedToken.slash(address(target), 180e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BasketChanged.selector, signedVersion, signedVersion + 2));
        target.redeem(SHARE, signedMinima, signedVersion);
        assertEq(protectedToken.balanceOf(ALICE), 0);
        assertEq(target.balanceOf(ALICE), SHARE);
    }

    /// @dev Sells whole reserves back and forth, each swap losing 1.9% of what it sells, until the
    /// guard refuses one for the week's limit; returns how many passed.
    function _lossySwapsUntilRefused(ChainlinkPriceGuard guard) internal returns (uint256 passed) {
        vm.startPrank(REBALANCER);
        for (; passed < 100; ++passed) {
            (address sold, address bought) =
                passed % 2 == 0 ? (address(healthy), address(faulty)) : (address(faulty), address(healthy));
            uint256 amount = vault.reserves()[passed % 2];
            uint256 received = guard.valueOf(sold, amount) * 981 / 1000 * 1e18 / guard.valueOf(bought, 1e18);
            try vault.swap(sold, amount, bought, received) {}
            catch (bytes memory reason) {
                assertEq(bytes4(reason), ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
                break;
            }
        }
        vm.stopPrank();
        assertLt(passed, 100);
    }

    /// @dev What Alice's GRET is worth at the guard's prices.
    function _aliceValue(ChainlinkPriceGuard guard) internal view returns (uint256) {
        uint256[] memory reserves = vault.reserves();
        uint256 total = guard.valueOf(address(healthy), reserves[0]) + guard.valueOf(address(faulty), reserves[1]);
        return total * vault.balanceOf(ALICE) / vault.totalSupply();
    }
}
