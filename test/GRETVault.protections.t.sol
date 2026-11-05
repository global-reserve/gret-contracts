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
import {
    GRETVaultCase, CaseToken, SenderSurchargeToken, GasBurnerToken, RedenominatingToken
} from "./helpers/GRETVaultCase.sol";

/// @dev A component whose ledger can also be moved through a second address, as an issuer upgrade
/// could create.
contract TwinLedgerToken is CaseToken {
    address public twin;

    constructor() CaseToken("Twin ledger") {}

    function setTwin(address twin_) external {
        twin = twin_;
    }

    function moveFrom(address from, address to, uint256 amount) external {
        require(msg.sender == twin, "only the twin");
        _transfer(from, to, amount);
    }
}

/// @dev The second address: its transfers and balances act on `TwinLedgerToken`'s ledger.
contract TwinAddress {
    TwinLedgerToken public immutable ledger;

    constructor(TwinLedgerToken ledger_) {
        ledger = ledger_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        ledger.moveFrom(msg.sender, to, amount);
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return ledger.balanceOf(account);
    }
}

/// @dev A contract governance can announce as a component; it reports an empty balance.
contract EmptyComponent {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Answers `word` padded to a size chosen from the gas received: about 60% of that gas pays
/// for the answer's memory, so a caller that copied the whole answer would run out of gas.
abstract contract OversizedAnswer {
    function _answer(uint256 word) internal view {
        uint256 target = gasleft() * 6 / 10;
        uint256 size = (Math.sqrt(1536 * 1536 + 2048 * target) - 1536) / 2 * 32;
        assembly ("memory-safe") {
            mstore(0, word)
            return(0, size)
        }
    }
}

/// @dev Once enabled, `balanceOf` answers the balance padded to an oversized payload.
contract OversizedBalanceToken is CaseToken, OversizedAnswer {
    constructor() CaseToken("Oversized balance") {}

    function balanceOf(address account) public view override returns (uint256 amount) {
        amount = super.balanceOf(account);
        if (enabled) _answer(amount);
    }
}

/// @dev A guard that is later replaced and whose `currentWeek` answers an oversized payload.
contract OversizedPredecessor is OversizedAnswer {
    function checkSwap(address, uint256, address, uint256, bytes calldata) external {}

    function currentWeek() external view returns (uint256 week) {
        week = block.timestamp / 7 days;
        _answer(week);
    }
}

/// @notice Protections: each test plays an attack or a failure and shows what the vault refuses
/// or lets holders do about it.
contract GRETVaultProtectionsTest is GRETVaultCase {
    function test_activationIsIdempotentAndOnlyEmitsOnStateChange() public {
        vm.recordLogs();
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(healthy));
        assertEq(vm.getRecordedLogs().length, 0);
        vm.startPrank(GOVERNANCE);
        vault.proposeWriteOff(address(healthy));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(healthy));
        vm.recordLogs();
        vault.activateComponent(address(healthy));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 1);
        assertFalse(vault.excluded(address(healthy)));
        assertTrue(vault.writtenOff(address(healthy)));
    }

    function test_activationAfterMintQuoteRespectsInputLimitsWithoutVersionChange() public {
        vm.startPrank(GOVERNANCE);
        vault.proposeWriteOff(address(healthy));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(healthy));
        uint256[] memory quote = vault.previewMint(SHARE);
        uint256 version = vault.basketVersion();
        vault.activateComponent(address(healthy));
        vault.setMintPaused(false);
        vm.stopPrank();
        assertEq(vault.basketVersion(), version);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.AmountInAboveMax.selector, 0, 2e18, 0));
        vm.prank(BOB);
        vault.mint(SHARE, BOB, quote, SHARE, version);
        assertEq(vault.totalSupply(), SHARE);
    }

    function test_writeOffAfterRedeemQuoteRespectsOutputLimitsWithoutVersionChange() public {
        uint256[] memory quote = vault.previewRedeem(SHARE);
        uint256 version = vault.basketVersion();
        vm.startPrank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));
        vm.stopPrank();
        assertEq(vault.basketVersion(), version);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.AmountOutBelowMin.selector, 1, 0, 5e18));
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, quote, version);
        assertEq(vault.balanceOf(ALICE), SHARE);
    }

    function test_deactivationAfterRedeemQuoteRespectsOutputLimitsWithoutVersionChange() public {
        faulty.slash(address(vault), 5e18 - 10);
        uint256[] memory quote = vault.previewRedeem(SHARE);
        uint256 version = vault.basketVersion();
        vm.prank(GOVERNANCE);
        vault.deactivateEmptyComponent(address(faulty));
        assertEq(vault.basketVersion(), version);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.AmountOutBelowMin.selector, 1, 0, 10));
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, quote, version);
        assertEq(vault.balanceOf(ALICE), SHARE);
    }

    // Issues that live-balance accounting closes.
    function test_liveDividendCannotBeCaptured() public {
        healthy.mint(address(vault), 100e18);
        uint256 before = healthy.balanceOf(BOB);
        vm.startPrank(BOB);
        vault.mint(99 * SHARE, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vault.redeem(99 * SHARE, BOB, _pair(0, 0), 0);
        vm.stopPrank();
        assertEq(healthy.balanceOf(BOB), before);
        assertEq(vault.reserves()[0], 102e18);
    }

    function test_brokenBalanceCannotOverpayFirstRedeemer() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        faulty.slash(address(vault), 5e18);
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.expectRevert(MockFaultyERC20.BalanceOfBlocked.selector);
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
        assertEq(faulty.rawBalanceOf(address(vault)), 5e18);
        assertEq(vault.balanceOf(ALICE), SHARE);
    }

    function test_emptyLiquidationIsRejected() public {
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
        vm.expectRevert(GRETVault.NoSupply.selector);
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        assertFalse(vault.liquidationActive());
    }

    /// `minAmount` lets the claimant refuse an unexpected cut and keep the right pending.
    function test_claimMinimumRefusesUnexpectedCut() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
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
        assertEq(vault.consumedRights(ALICE, 1), 0);

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
        vault.mint(SHARE, BOB, _pair(2e18, 11), minShares, 0);
        assertEq(healthy.balanceOf(BOB), before);
        assertEq(vault.balanceOf(BOB), 0);
    }

    /// A holder who never minted redeems directly, even after a component's total loss.
    function test_secondaryHolderRedeemsAfterTotalLoss() public {
        vm.prank(ALICE);
        vault.transfer(BOB, SHARE);
        faulty.slash(address(vault), 5e18);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        uint256[] memory paid = vault.redeem(SHARE, BOB, _pair(0, 0), 0);
        assertEq(paid[1], 0);
        assertEq(healthy.balanceOf(BOB) - before, 2e18);
        assertEq(vault.totalSupply(), 0);
    }

    /// Without an eligibility contract, a holder who never minted leaves while minting is paused
    /// and a component is frozen, so a captured governance cannot keep secondary holders in
    /// during the notice of a new rebalancer.
    function test_secondaryHolderLeavesWhileMintIsPausedAndComponentFrozen() public {
        vm.prank(ALICE);
        vault.transfer(BOB, SHARE);
        vm.prank(GOVERNANCE);
        vault.setMintPaused(true);
        faulty.setBlocked(address(vault), true);
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.redeemSkipping(SHARE, BOB, _pair(0, 0), skipped, 0);
        assertEq(healthy.balanceOf(BOB) - before, 2e18);
        assertEq(vault.totalSupply(), 0);
    }

    /// A skipping exit that empties the supply pauses minting, so nobody bootstraps onto the
    /// skipped residue before governance has dealt with it.
    function test_lastNormalExitPausesMintUntilGovernanceReviewsResidue() public {
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.expectEmit(address(vault));
        emit GRETVault.MintPauseChanged(true);
        vm.prank(ALICE);
        vault.redeemSkipping(SHARE, ALICE, _pair(0, 0), skipped, 0);
        assertEq(vault.totalSupply(), 0);
        assertTrue(vault.mintPaused());
        assertEq(faulty.balanceOf(address(vault)), 5e18);

        vm.expectRevert(GRETVault.MintIsPaused.selector);
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), SHARE, 0);

        vm.startPrank(GOVERNANCE);
        vault.rescue(address(faulty), ALICE, 5e18); // back to the holder who skipped it
        vault.setMintPaused(false);
        vm.stopPrank();
        vm.startPrank(BOB);
        vault.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), SHARE, 0);
        uint256[] memory paid = vault.redeem(SHARE, BOB, _pair(0, 0), 0);
        vm.stopPrank();
        assertEq(paid[0], 2e18);
        assertEq(paid[1], 5e18);
    }

    /// A normal exit of the whole supply pays out every active balance, so it does not pause.
    function test_normalLastExitLeavesNothingAndDoesNotPause() public {
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(healthy.balanceOf(address(vault)), 0);
        assertEq(faulty.balanceOf(address(vault)), 0);
        assertFalse(vault.mintPaused());
    }

    /// A skipping exit that leaves holders behind does not pause either.
    function test_skippingExitThatLeavesHoldersDoesNotPause() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), SHARE, 0);
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.prank(ALICE);
        vault.redeemSkipping(SHARE, ALICE, _pair(0, 0), skipped, 0);
        assertEq(vault.totalSupply(), SHARE);
        assertFalse(vault.mintPaused());
    }

    /// A rescue that would leave less than what is owed reverts.
    function test_rescueCannotReduceBackingThroughSenderFee() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        token.mint(address(single), 1e18);
        token.enable();
        // The 1% sender debit would leave 199.99 behind 200 owed.
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BackingToken.selector, address(token)));
        vm.prank(GOVERNANCE);
        single.rescue(address(token), CAROL, 1e18);
        assertEq(token.balanceOf(address(single)), 201e18);
        assertEq(token.balanceOf(CAROL), 0);
    }

    /// A second address over a component's ledger is a foreign token to the vault, but moving it
    /// would move the component's balance: the rescue reverts.
    function test_rescueCannotMoveComponentThroughSecondAddress() public {
        TwinLedgerToken token = new TwinLedgerToken();
        GRETVault single = _single(token, 100e18);
        TwinAddress twin = new TwinAddress(token);
        token.setTwin(address(twin));
        assertEq(twin.balanceOf(address(single)), 200e18);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentBalanceReduced.selector, address(token)));
        vm.prank(GOVERNANCE);
        single.rescue(address(twin), CAROL, 200e18);
        assertEq(token.balanceOf(address(single)), 200e18);
    }

    /// A component whose balance cannot be read does not block the rescue of a foreign token.
    function test_rescueOfForeignTokenSkipsUnreadableComponent() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 1e18);
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.prank(GOVERNANCE);
        vault.rescue(address(stray), CAROL, 1e18);
        assertEq(stray.balanceOf(CAROL), 1e18);
    }

    /// Reactivating a component the vault cannot send blocks `redeem`, but `redeemSkipping` lets holders
    /// leave with the other components during the seven-day notice of a new rebalancer.
    function test_holdersExitDuringRebalancerNoticeBySkipping() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
        faulty.setBlocked(address(vault), true);
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));

        // A captured governance reactivates the frozen balance and appoints its rebalancer.
        vm.startPrank(GOVERNANCE);
        vault.activateComponent(address(faulty));
        vault.proposeRebalancer(REBALANCER);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MockFaultyERC20.AccountBlocked.selector, address(vault)));
        vm.prank(BOB);
        vault.redeem(SHARE / 4, BOB, _pair(0, 0), 0);

        // During the notice, Bob leaves with his share of everything that still moves.
        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.redeemSkipping(SHARE / 4, BOB, _pair(0, 0), skipped, 0);
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
        target.mint(SHARE, ALICE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.stopPrank();

        burner.enable();
        vm.expectRevert();
        vm.prank(ALICE);
        target.redeem{gas: 5_000_000}(SHARE, ALICE, _pair(0, 0), 0);

        address[] memory skipped = new address[](1);
        skipped[0] = address(burner);
        uint256 before = healthy.balanceOf(ALICE);
        vm.prank(ALICE);
        target.redeemSkipping{gas: 5_000_000}(SHARE, ALICE, _pair(0, 0), skipped, 0);
        assertEq(healthy.balanceOf(ALICE) - before, 2e18);
    }

    /// A written-off component cannot be removed, so there is never a seven-day re-announcement to
    /// exploit, and a recovery during liquidation counts automatically.
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
        assertEq(vault.pendingRights(ALICE, 1), 5e18);

        // The issuer lifts the freeze: the right can be claimed with no further step.
        faulty.setBlocked(address(vault), false);
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
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotProposed.selector, REBALANCER));
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
        vault.swap(address(healthy), 2e18, address(faulty), 1, "");
        // Each swap loses $1.90, 1.9% of the $100 it sells and about 0.48% of the vault.
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18, "");
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18, "");
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18, "");
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18, "");
        vm.expectPartialRevert(ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
        vault.swap(address(faulty), 2.5e18, address(healthy), 0.981e18, "");
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
        vault.mint(99 * SHARE, REBALANCER, _pair(198e18, 495e18), 99 * SHARE, 0);
        // With $40,000 in the vault, a swap that loses $0.10.
        vault.swap(address(healthy), 1e18, address(faulty), 2.4975e18, "");
        vault.redeem(99 * SHARE, REBALANCER, _pair(0, 0), 0);
        vm.stopPrank();
        assertLe(_lossySwapsUntilRefused(guard), 2);
        assertGe(_aliceValue(guard), before * 98 / 100);
    }

    /// The same after an ordinary large exit: the limit shrinks with what is left.
    function test_priceGuardLimitShrinksWithRedemptions() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        uint256 before = _aliceValue(guard);
        vm.prank(BOB);
        vault.mint(99 * SHARE, BOB, _pair(198e18, 495e18), 99 * SHARE, 0);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), 2.4975e18, "");
        vm.prank(BOB);
        vault.redeem(99 * SHARE, BOB, _pair(0, 0), 0);
        assertLe(_lossySwapsUntilRefused(guard), 2);
        assertGe(_aliceValue(guard), before * 98 / 100);
    }

    /// A balance the vault no longer holds does not stretch the limit. Healthy H and O are worth
    /// $100 each and F $19,800, all at $1; F's issuer then takes the whole F balance.
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
        target.mint(SHARE, ALICE, initial, SHARE, 0);
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
        assertEq(target.reserves()[2], 0);

        // Each swap sells a whole healthy reserve for 98% of its value. The first takes 1% of the
        // $200 left; the second would take 2% more.
        vm.startPrank(REBALANCER);
        target.swap(address(healthy), 100e18, address(other), 98e18, "");
        vm.expectPartialRevert(ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
        target.swap(address(other), 198e18, address(healthy), 194.04e18, "");
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
            target.mint(SHARE, user, initial, SHARE, 0);
            vm.stopPrank();
        }
        vm.prank(GOVERNANCE);
        target.announceComponent(address(extra));
        _appoint(target, address(new MockPriceGuard()));
        last.mint(REBALANCER, 2e18);
        vm.startPrank(REBALANCER);
        last.approve(address(target), 2e18);
        target.swap(address(first), 2e18, address(last), 2e18, "");
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
        target.redeem(SHARE, ALICE, signedMinima, signedVersion);
        assertEq(protectedToken.balanceOf(ALICE), 0);
        assertEq(target.balanceOf(ALICE), SHARE);
    }

    /// A hostile governance changes the basket version before each prepared redemption, for example
    /// during the notice of a rebalancer whose guard accepts every swap. Positional minima are
    /// refused, but minima that are all zero, or none, limit nothing: such redemptions are not tied
    /// to the version and go through, so the notice still lets holders leave.
    function test_redemptionsWithoutMinimaIgnoreBasketChanges() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
        address[] memory junk = new address[](2);
        vm.startPrank(GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            junk[i] = address(new EmptyComponent());
            vault.announceComponent(junk[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(new MockPriceGuard()));
        vm.stopPrank();

        // Bob prepared his redemptions for this version and two components.
        uint256 prepared = vault.basketVersion();
        vault.addComponent(junk[0]);
        vault.addComponent(junk[1]);
        vm.prank(GOVERNANCE);
        vault.removeComponent(junk[0]); // also moves junk[1] down one position
        assertEq(vault.basketVersion(), prepared + 3);

        vm.expectRevert(abi.encodeWithSelector(GRETVault.BasketChanged.selector, prepared, prepared + 3));
        vm.prank(BOB);
        vault.redeem(SHARE / 4, BOB, _pair(1, 0), prepared);

        address[] memory none = new address[](0);
        uint256 healthyBefore = healthy.balanceOf(BOB);
        uint256 faultyBefore = faulty.balanceOf(BOB);
        vm.startPrank(BOB);
        vault.redeem(SHARE / 4, BOB, _pair(0, 0), prepared);
        vault.redeem(SHARE / 4, BOB, new uint256[](0), prepared);
        vault.redeemSkipping(SHARE / 4, BOB, _pair(0, 0), none, prepared);
        vault.redeemSkipping(SHARE / 4, BOB, new uint256[](0), none, prepared);
        vm.stopPrank();
        assertEq(vault.balanceOf(BOB), 0);
        assertEq(healthy.balanceOf(BOB) - healthyBefore, 2e18);
        assertEq(faulty.balanceOf(BOB) - faultyBefore, 5e18);
        (, uint256 readyAt) = vault.rebalancerProposal();
        assertLt(block.timestamp, readyAt);
    }

    /// A token announced for the basket can join and be activated at once, and every exit that does
    /// not skip it then calls it. An exit prepared without minima that already lists the announced
    /// token goes through even if every call to that token reverts; listed addresses that are not
    /// components are ignored.
    function test_preparedExitSkipsAnnouncedTokenBeforeItJoins() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
        MockFaultyERC20 joining = new MockFaultyERC20("Joining", "J", 18);
        vm.prank(GOVERNANCE);
        vault.announceComponent(address(joining));

        // Bob prepares his exit now, listing the announced token and an address outside the basket.
        address[] memory skipped = new address[](2);
        skipped[0] = address(joining);
        skipped[1] = CAROL;
        uint256 prepared = vault.basketVersion();
        assertEq(vault.previewRedeemSkipping(SHARE, skipped), vault.previewRedeem(SHARE));

        vm.warp(block.timestamp + 7 days);
        vault.addComponent(address(joining));
        joining.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(joining));

        uint256 healthyBefore = healthy.balanceOf(BOB);
        uint256 faultyBefore = faulty.balanceOf(BOB);
        vm.prank(BOB);
        vault.redeemSkipping(SHARE, BOB, new uint256[](0), skipped, prepared);
        assertEq(vault.balanceOf(BOB), 0);
        assertEq(healthy.balanceOf(BOB) - healthyBefore, 2e18);
        assertEq(faulty.balanceOf(BOB) - faultyBefore, 5e18);
    }

    /// The guard reads each token's decimals at deployment. If an issuer changes them and rescales
    /// the balances, keeping their value, those decimals would misprice every unit by a power of
    /// ten. The guard refuses to value the token instead: swaps of it revert in either direction,
    /// and it counts as zero in the vault's value. H and O are worth $100 and R $40.
    function test_guardRefusesTokenWhoseDecimalsChanged() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        RedenominatingToken redenominated = new RedenominatingToken(18);
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = healthy;
        basket[1] = other;
        basket[2] = IERC20(address(redenominated));
        uint256[] memory initial = _three(1e18, 1e18, 5e18);
        GRETVault target = new GRETVault(basket, initial, GOVERNANCE);
        other.mint(ALICE, 1e18);
        redenominated.mint(ALICE, 5e18);
        other.mint(REBALANCER, 1e24);
        redenominated.mint(REBALANCER, 1e24);
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(i == 0 ? ALICE : REBALANCER);
            for (uint256 j; j < 3; ++j) {
                basket[j].approve(address(target), type(uint256).max);
            }
            vm.stopPrank();
        }
        vm.prank(ALICE);
        target.mint(SHARE, ALICE, initial, SHARE, 0);

        MockAggregator usd100 = new MockAggregator(8, 100e8);
        MockAggregator usd40 = new MockAggregator(8, 40e8);
        address[] memory tokens = new address[](3);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](3);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = address(basket[i]);
            feeds[i] = IChainlinkFeed(address(i == 2 ? usd40 : usd100));
        }
        ChainlinkPriceGuard guard =
            new ChainlinkPriceGuard(address(target), tokens, feeds, _three(1 days, 1 days, 1 days));
        _appoint(target, address(guard));
        usd100.setAnswer(100e8);
        usd40.setAnswer(40e8);
        assertEq(guard.valueOf(address(redenominated), 5e18), 200e18);

        address[] memory holders = new address[](2);
        holders[0] = address(target);
        holders[1] = REBALANCER;
        redenominated.redenominate(6, holders); // the vault's 5 R are now 5e6 units of 6 decimals
        bytes memory refused = abi.encodeWithSelector(
            ChainlinkPriceGuard.DecimalsChanged.selector, address(redenominated), 18, 6
        );
        vm.expectRevert(refused);
        guard.valueOf(address(redenominated), 5e6);

        vm.startPrank(REBALANCER);
        // The whole R reserve for one unit of H, and all of H for one unit of R.
        vm.expectRevert(refused);
        target.swap(address(redenominated), 5e6, address(healthy), 1, "");
        vm.expectRevert(refused);
        target.swap(address(healthy), 1e18, address(redenominated), 1, "");
        // H for O at a $1 loss counts against the $200 of H and O alone.
        target.swap(address(healthy), 1e18, address(other), 0.99e18, "");
        vm.stopPrank();
        assertEq(guard.weeklyLoss(), 5e15);
        assertEq(redenominated.balanceOf(address(target)), 5e6);
    }

    /// The guard in place can be proposed and applied again as its own successor. Its first loss in a
    /// later week then starts from zero, not from the total of the week it last recorded. H is worth
    /// $100 and F $40; each swap sells 1 H for 2.4525 F, a $1.90 loss.
    function test_guardReappliedAsItsOwnSuccessorStartsEachWeekAtZero() public {
        ChainlinkPriceGuard guard = _chainlinkGuard();
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18, "");
        assertEq(guard.weeklyLoss(), 4.75e15); // $1.90 of $400
        uint256 lastWeek = guard.currentWeek();

        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(guard));
        vm.warp(_priceGuardReadyAt());
        vault.applyPriceGuard();
        assertEq(vault.previousPriceGuard(), address(guard));
        (address healthyFeed,) = guard.priceFeed(address(healthy));
        (address faultyFeed,) = guard.priceFeed(address(faulty));
        MockAggregator(healthyFeed).setAnswer(100e8);
        MockAggregator(faultyFeed).setAnswer(40e8);

        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), 2.4525e18, "");
        assertGt(guard.currentWeek(), lastWeek);
        // $1.90 of the $398.10 left, and nothing from the earlier week.
        assertEq(guard.weeklyLoss(), Math.mulDiv(1.9e18, 1e18, 398.1e18, Math.Rounding.Ceil));
    }

    /// The vault refuses its own address as a component with `InvalidContract`, also in the
    /// constructor, while that address has no code yet.
    function test_constructorRefusesTheVaultItselfAsComponent() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        IERC20[] memory basket = new IERC20[](1);
        basket[0] = IERC20(next);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, next));
        new GRETVault(basket, _one(1), GOVERNANCE);
    }

    /// A component whose `balanceOf` answers an oversized payload, or burns all the gas it gets,
    /// cannot block `rescue` of other tokens: each read gets limited gas and only its first word is
    /// copied.
    function test_oversizedOrCostlyBalanceReadDoesNotBlockRescue() public {
        OversizedBalanceToken oversized = new OversizedBalanceToken();
        GasBurnerToken burner = new GasBurnerToken();
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = oversized;
        basket[1] = burner;
        basket[2] = healthy;
        uint256[] memory initial = _three(1e18, 1e18, 1e18);
        GRETVault target = new GRETVault(basket, initial, GOVERNANCE);
        oversized.mint(ALICE, 1e18);
        burner.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        for (uint256 i; i < 3; ++i) {
            basket[i].approve(address(target), type(uint256).max);
        }
        target.mint(SHARE, ALICE, initial, SHARE, 0);
        vm.stopPrank();
        MockERC20 foreign = new MockERC20("Foreign", "FX", 18);
        foreign.mint(address(target), 1e18); // sent to the vault by mistake

        oversized.enable();
        burner.enable();
        vm.prank(GOVERNANCE);
        target.rescue{gas: 16_777_216}(address(foreign), CAROL, 1e18);
        assertEq(foreign.balanceOf(CAROL), 1e18);
    }

    /// A replaced guard whose `currentWeek` answers an oversized payload counts as zero, like one
    /// that reverts, instead of making every lossy swap of its successor run out of gas.
    function test_oversizedPredecessorAnswerCountsAsZero() public {
        _appoint(vault, address(new OversizedPredecessor()));
        ChainlinkPriceGuard guard = _chainlinkGuard();
        // 1 H ($100) for 2.45025 F ($98.01): a 1.99% loss, of the $400 vault.
        vm.prank(REBALANCER);
        vault.swap{gas: 16_777_216}(address(healthy), 1e18, address(faulty), 2.45025e18, "");
        assertEq(guard.weeklyLoss(), 4.975e15);
    }

    /// A priced component whose `balanceOf` answers an oversized payload does not make the guard's
    /// valuation of the vault run out of gas: only the first word is read. H, O and X are worth $100.
    function test_oversizedPricedBalanceDoesNotBlockLossySwaps() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        OversizedBalanceToken oversized = new OversizedBalanceToken();
        IERC20[] memory basket = new IERC20[](3);
        basket[0] = healthy;
        basket[1] = other;
        basket[2] = oversized;
        uint256[] memory initial = _three(1e18, 1e18, 1e18);
        GRETVault target = new GRETVault(basket, initial, GOVERNANCE);
        other.mint(ALICE, 1e18);
        other.mint(REBALANCER, 1e24);
        oversized.mint(ALICE, 1e18);
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(i == 0 ? ALICE : REBALANCER);
            for (uint256 j; j < 3; ++j) {
                basket[j].approve(address(target), type(uint256).max);
            }
            vm.stopPrank();
        }
        vm.prank(ALICE);
        target.mint(SHARE, ALICE, initial, SHARE, 0);
        MockAggregator usd100 = new MockAggregator(8, 100e8);
        address[] memory tokens = new address[](3);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](3);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = address(basket[i]);
            feeds[i] = IChainlinkFeed(address(usd100));
        }
        ChainlinkPriceGuard guard =
            new ChainlinkPriceGuard(address(target), tokens, feeds, _three(1 days, 1 days, 1 days));
        _appoint(target, address(guard));
        usd100.setAnswer(100e8);

        oversized.enable();
        // H for O at a $1 loss, measured against the $300 of H, O and X.
        vm.prank(REBALANCER);
        target.swap{gas: 16_777_216}(address(healthy), 1e18, address(other), 0.99e18, "");
        assertEq(guard.weeklyLoss(), Math.mulDiv(1e18, 1e18, 300e18, Math.Rounding.Ceil));
    }

    /// At most 128 tokens can be announced and waiting at once. An addition or a cancellation frees a
    /// slot, and announcing a waiting token again restarts its wait without taking another.
    function test_pendingAnnouncementsAreCapped() public {
        uint256 max = vault.MAX_PENDING_ANNOUNCEMENTS();
        address[] memory announced = new address[](max);
        for (uint256 i; i < max; ++i) {
            announced[i] = address(new EmptyComponent());
        }
        address extra = address(new EmptyComponent());
        vm.startPrank(GOVERNANCE);
        for (uint256 i; i < max; ++i) {
            vault.announceComponent(announced[i]);
        }
        assertEq(vault.pendingAnnouncements(), max);
        vm.expectRevert(GRETVault.TooManyAnnouncements.selector);
        vault.announceComponent(extra);
        vault.announceComponent(announced[0]);
        vault.cancelComponentAnnouncement(announced[1]);
        vault.announceComponent(extra);
        vm.stopPrank();
        assertEq(vault.pendingAnnouncements(), max);
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(announced[2]);
        assertEq(vault.pendingAnnouncements(), max - 1);
    }

    /// With every slot taken, an exit prepared in advance lists all 128 waiting tokens and still fits
    /// well within a transaction. When governance adds one of them and activates it at once, with
    /// every call to it reverting, the exit goes through.
    function test_preparedExitListingEveryAnnouncementSurvivesTheirActivation() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
        uint256 max = vault.MAX_PENDING_ANNOUNCEMENTS();
        MockFaultyERC20 joining = new MockFaultyERC20("Joining", "J", 18);
        address[] memory skipped = new address[](max);
        skipped[0] = address(joining);
        for (uint256 i = 1; i < max; ++i) {
            skipped[i] = address(new EmptyComponent());
        }
        vm.startPrank(GOVERNANCE);
        for (uint256 i; i < max; ++i) {
            vault.announceComponent(skipped[i]);
        }
        vm.stopPrank();
        uint256 prepared = vault.basketVersion();

        vm.warp(block.timestamp + 7 days);
        vault.addComponent(address(joining));
        joining.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(joining));

        uint256 healthyBefore = healthy.balanceOf(BOB);
        vm.prank(BOB);
        uint256 gasBefore = gasleft();
        vault.redeemSkipping(SHARE, BOB, new uint256[](0), skipped, prepared);
        assertLt(gasBefore - gasleft(), 2_000_000);
        assertEq(vault.balanceOf(BOB), 0);
        assertEq(healthy.balanceOf(BOB) - healthyBefore, 2e18);
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
            try vault.swap(sold, amount, bought, received, "") {}
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
