// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";

/// @dev Audit-only model: transfers debit the requested amount and deliver up to ten units less.
contract AuditShortfallToken is ERC20 {
    uint256 public shortfall;

    constructor() ERC20("Audit shortfall", "ASF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function slash(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount != 0) {
            uint256 lost = Math.min(shortfall, amount - 1);
            if (lost != 0) super._update(from, address(0), lost);
            amount -= lost;
        }
        super._update(from, to, amount);
    }
}

/// @notice Economic properties across receipt rounding, live losses, donations and fees.
/// @dev Complements the existing invariant handler, whose transfer models deliver exact amounts
/// and whose losses are recognized immediately. These tokens are hypothetical, not issuer models.
contract GRETVaultAuditAccountingTest is Test {
    address private constant GOVERNANCE = address(0x60F);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant RECIPIENT = address(0xFEE);
    uint256 private constant SHARE = 1e18;

    GRETVault private vault;
    MockERC20 private healthy;
    AuditShortfallToken private rounding;

    function testFuzz_shortfallsLossesDonationsAndFeesNeverDiluteOrProfit(
        uint256 initial,
        uint256 shares,
        uint256 donation,
        uint256 loss,
        uint256 settings
    ) public {
        initial = bound(initial, 1, 1e24);
        shares = bound(shares, SHARE, 1e24);
        _deploy(initial);

        vm.startPrank(GOVERNANCE);
        vault.setFeeRecipient(RECIPIENT);
        vault.proposeFees(settings % 501, (settings / 501) % 501);
        vm.stopPrank();
        if (vault.pendingFeesReadyAt() != 0) {
            vm.warp(block.timestamp + 7 days);
            vault.applyFees();
        }

        donation = bound(donation, 0, initial);
        rounding.mint(address(vault), donation);
        loss = bound(loss, 0, initial + donation - 1);
        rounding.slash(address(vault), loss);
        rounding.setShortfall((settings / (501 * 501)) % 11);

        uint256 beforeHealthy = healthy.balanceOf(BOB);
        uint256 beforeRounding = rounding.balanceOf(BOB);
        uint256 effectiveReserve = rounding.balanceOf(address(vault));
        vm.prank(BOB);
        (uint256 issued,) = vault.mint(shares, _pair(type(uint256).max, type(uint256).max), 1, 0);

        uint256 supply = vault.totalSupply();
        uint256[] memory reserves = vault.reserves();
        assertGe(reserves[0] * SHARE, 2e18 * supply, "healthy backing diluted");
        assertGe(reserves[1] * SHARE, effectiveReserve * supply, "rounding backing diluted");
        assertGe(healthy.balanceOf(address(vault)), reserves[0], "healthy reserve insolvent");
        assertGe(rounding.balanceOf(address(vault)), reserves[1], "rounding reserve insolvent");

        vm.prank(BOB);
        vault.redeem(issued, _pair(0, 0), 0);
        assertLe(healthy.balanceOf(BOB), beforeHealthy, "healthy roundtrip profit");
        assertLe(rounding.balanceOf(BOB), beforeRounding, "rounding roundtrip profit");
    }

    function _deploy(uint256 initial) private {
        healthy = new MockERC20("Audit healthy", "AHL", 18);
        rounding = new AuditShortfallToken();
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy;
        basket[1] = rounding;
        vault = new GRETVault(basket, _pair(2e18, initial), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? ALICE : BOB;
            healthy.mint(actor, 1e40);
            rounding.mint(actor, 1e40);
            vm.startPrank(actor);
            healthy.approve(address(vault), type(uint256).max);
            rounding.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(ALICE);
        vault.mint(SHARE, _pair(2e18, initial), SHARE, 0);
    }

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = a;
        amounts[1] = b;
    }
}

/// @notice Live accounting regression tests against the production vault and price guard.
contract GRETVaultLiveBalanceTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SHARE = 1e18;
    MockERC20 private healthy;
    MockFaultyERC20 private faulty;
    GRETVault private vault;

    function setUp() public {
        healthy = new MockERC20("Live healthy", "LH", 18);
        faulty = new MockFaultyERC20("Live faulty", "LF", 18);
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy; basket[1] = faulty;
        vault = new GRETVault(basket, _pair(100e18, 100e18), address(this));
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? ALICE : BOB;
            healthy.mint(actor, 1e36); faulty.mint(actor, 1e36);
            vm.startPrank(actor);
            healthy.approve(address(vault), type(uint256).max);
            faulty.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(ALICE);
        vault.mint(SHARE, _pair(100e18, 100e18), SHARE, 0);
    }

    function test_liveBalance_existingDividendCannotBeCaptured() public {
        healthy.mint(address(vault), 10e18);
        uint256 before = healthy.balanceOf(BOB);
        vm.startPrank(BOB);
        vault.mint(9 * SHARE, _pair(990e18, 900e18), 9 * SHARE, 0);
        vault.redeem(9 * SHARE, _pair(0, 0), 0);
        vm.stopPrank();
        assertEq(healthy.balanceOf(BOB), before);
        assertEq(vault.reserves()[0], 110e18);
    }

    function testFuzz_liveBalance_donationThenRoundtripNeverProfits(uint256 donation, uint256 shares) public {
        donation = bound(donation, 0, 1e24); shares = bound(shares, 1, 1e24);
        healthy.mint(address(vault), donation);
        uint256 before = healthy.balanceOf(BOB);
        vm.startPrank(BOB);
        vault.mint(shares, _pair(type(uint256).max, type(uint256).max), shares, 0);
        vault.redeem(shares, _pair(0, 0), 0);
        vm.stopPrank();
        assertLe(healthy.balanceOf(BOB), before);
        assertGe(vault.reserves()[0], 100e18 + donation);
    }

    function test_liveBalance_exclusionDoesNotReadBrokenToken() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        _writeOff();
        vm.startPrank(BOB);
        vault.mint(SHARE, _pair(100e18, 0), SHARE, 0);
        vault.redeem(SHARE, _pair(0, 0), 0);
        vm.stopPrank();
        assertEq(faulty.rawBalanceOf(address(vault)), 100e18);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.TokenWrittenOff.selector, address(faulty)));
        vault.rescue(address(faulty), ALICE, 1);
    }

    function test_liveBalance_oneUnitCanReactivateAnActiveZeroBalance() public {
        faulty.slash(address(vault), 100e18);
        faulty.setBlocked(BOB, true);
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 0), SHARE, 0);
        faulty.mint(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(MockFaultyERC20.AccountBlocked.selector, BOB));
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 1), SHARE, 0);
        vault.deactivateEmptyComponent(address(faulty));
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 0), SHARE, 0);
    }

    function test_liveBalance_newComponentStaysInactiveUntilExplicitActivation() public {
        MockFaultyERC20 extra = new MockFaultyERC20("Extra", "EX", 18);
        vault.announceComponent(address(extra));
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(address(extra));
        extra.mint(address(vault), 100e18);
        extra.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        assertTrue(vault.excluded(address(extra)));
        assertEq(vault.previewMint(SHARE)[2], 0);
        extra.setFault(MockFaultyERC20.Fault.None);
        vault.activateComponent(address(extra));
        assertEq(vault.previewMint(SHARE)[2], 100e18);
    }

    function test_liveBalance_dustRetirementIsBoundedAndCannotBypassWriteOff() public {
        faulty.slash(address(vault), 100e18 - 11);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(faulty), 11));
        vault.removeComponent(address(faulty));
        faulty.slash(address(vault), 1);
        vault.deactivateEmptyComponent(address(faulty));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BackingToken.selector, address(faulty)));
        vault.rescue(address(faulty), ALICE, 10);
        vault.removeComponent(address(faulty));
        vault.rescue(address(faulty), ALICE, 10);
        assertEq(faulty.rawBalanceOf(address(vault)), 0);
    }

    function test_liveBalance_removalToleranceCannotDiscardLowDecimalAssets() public {
        MockERC20 indivisible = new MockERC20("Indivisible", "ONE", 0);
        vault.announceComponent(address(indivisible));
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(address(indivisible));
        indivisible.mint(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(indivisible), 1));
        vault.removeComponent(address(indivisible));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentHasReserve.selector, address(indivisible), 1));
        vault.deactivateEmptyComponent(address(indivisible));
    }

    function test_liveBalance_skippingQuoteAndExitNeverReadBrokenToken() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        address[] memory skipped = new address[](1); skipped[0] = address(faulty);
        uint256[] memory quote = vault.previewRedeemSkipping(SHARE, skipped);
        assertEq(quote[0], 100e18); assertEq(quote[1], 0);
        vm.prank(ALICE);
        vault.redeemSkipping(SHARE, quote, skipped, 0);
    }

    function test_liveBalance_bootstrapOwnsOldActiveReceipts() public {
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        healthy.mint(address(vault), 10e18);
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 100e18), SHARE, 0);
        assertEq(vault.previewRedeem(SHARE)[0], 110e18);
    }

    function test_liveBalance_emptyNormalComponentCanBeRescuedButNotAfterRestart() public {
        vm.prank(ALICE);
        vault.redeem(SHARE, _pair(0, 0), 0);
        healthy.mint(address(vault), 10);
        vault.rescue(address(healthy), ALICE, 10);
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 100e18), SHARE, 0);
        healthy.mint(address(vault), 10);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BackingToken.selector, address(healthy)));
        vault.rescue(address(healthy), ALICE, 10);
    }

    function test_liveBalance_liquidationActivatesAndHealthyClaimWorksWithBrokenToken() public {
        faulty.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vault.activateLiquidation();
        vm.startPrank(ALICE);
        vault.convertToClaims(SHARE);
        assertEq(vault.claim(0, ALICE, 0), 100e18);
        vm.expectRevert(MockFaultyERC20.BalanceOfBlocked.selector);
        vault.claim(1, ALICE, 0);
        vm.stopPrank();
        assertEq(vault.claimed(ALICE, 1), 0);
        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(ALICE);
        assertEq(vault.claim(1, ALICE, 0), 100e18);
    }

    function test_liveBalance_paidHoldersCanClaimLateIncomeAutomatically() public {
        _splitAndConvert(SHARE / 2);
        vm.prank(ALICE); assertEq(vault.claim(0, ALICE, 0), 50e18);
        vm.prank(BOB); assertEq(vault.claim(0, BOB, 0), 50e18);
        healthy.mint(address(vault), 20e18);
        vm.prank(ALICE); assertEq(vault.claim(0, ALICE, 0), 10e18);
        vm.prank(BOB); assertEq(vault.claim(0, BOB, 0), 10e18);
    }

    function test_liveBalance_lazyBasisUsesBalanceAtFirstSuccessfulClaim() public {
        _splitAndConvert(SHARE / 2);
        faulty.slash(address(vault), 50e18);
        vm.prank(ALICE); assertEq(vault.claim(1, ALICE, 0), 25e18);
        faulty.mint(address(vault), 50e18);
        vm.prank(ALICE); assertEq(vault.claim(1, ALICE, 0), 25e18);
        vm.prank(BOB); assertEq(vault.claim(1, BOB, 0), 50e18);
    }

    function testFuzz_liveBalance_lateIncomePreservesEveryHoldersFraction(uint256 donation, uint256 fraction) public {
        donation = bound(donation, 2, 1e24); fraction = bound(fraction, 1, SHARE - 1);
        _splitAndConvert(fraction);
        vm.prank(ALICE); vault.claim(0, ALICE, 0);
        vm.prank(BOB); vault.claim(0, BOB, 0);
        healthy.mint(address(vault), donation);
        uint256 aliceBefore = healthy.balanceOf(ALICE);
        uint256 bobBefore = healthy.balanceOf(BOB);
        vm.prank(ALICE); try vault.claim(0, ALICE, 0) {} catch {}
        vm.prank(BOB); try vault.claim(0, BOB, 0) {} catch {}
        assertApproxEqAbs(healthy.balanceOf(ALICE) - aliceBefore, Math.mulDiv(donation, fraction, SHARE), 1);
        assertApproxEqAbs(healthy.balanceOf(BOB) - bobBefore, Math.mulDiv(donation, SHARE - fraction, SHARE), 1);
        assertLe(healthy.balanceOf(address(vault)), 1);
    }

    function test_liveBalance_guardExcludesIncomingBuyAndRespectsWeeklyLimit() public {
        faulty.slash(address(vault), 100e18);
        ChainlinkPriceGuard guard = _guard();
        faulty.mint(address(this), 98.1e18);
        faulty.approve(address(vault), type(uint256).max);
        healthy.approve(address(vault), type(uint256).max);
        vault.swap(address(healthy), 100e18, address(faulty), 98.1e18);
        assertEq(guard.weeklyLoss(), 0.019e18);
        vm.expectPartialRevert(ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
        vault.swap(address(faulty), 98.1e18, address(healthy), 96.2361e18);
    }

    function test_liveBalance_excludedComponentCannotBeBoughtBackByRebalancer() public {
        _guard(); _writeOff();
        faulty.mint(address(this), 100e18); faulty.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentExcluded.selector, address(faulty)));
        vault.swap(address(healthy), 1e18, address(faulty), 1e18);
    }

    function test_liveBalance_sensitiveViewsRejectTokenCallbacks() public {
        faulty.setReentry(address(vault), abi.encodeCall(GRETVault.previewMint, (SHARE)));
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        vm.prank(BOB);
        vault.mint(SHARE, _pair(100e18, 100e18), SHARE, 0);
        assertEq(vault.totalSupply(), SHARE);
    }

    function _writeOff() private {
        vault.proposeWriteOff(address(faulty));
        vm.warp(block.timestamp + 7 days);
        vault.writeOffComponent(address(faulty));
    }

    function _splitAndConvert(uint256 aliceFraction) private {
        vm.prank(ALICE); vault.transfer(BOB, SHARE - aliceFraction);
        vault.activateLiquidation();
        vm.prank(ALICE); vault.convertToClaims(aliceFraction);
        vm.prank(BOB); vault.convertToClaims(SHARE - aliceFraction);
    }

    function _guard() private returns (ChainlinkPriceGuard guard) {
        vault.proposeRebalancer(address(this));
        vm.warp(block.timestamp + 7 days); vault.acceptRebalancer();
        address[] memory tokens = new address[](2); tokens[0] = address(healthy); tokens[1] = address(faulty);
        MockAggregator feed = new MockAggregator(8, 1e8);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](2); feeds[0] = IChainlinkFeed(address(feed)); feeds[1] = feeds[0];
        guard = new ChainlinkPriceGuard(address(vault), tokens, feeds, _pair(30 days, 30 days));
        vault.proposePriceGuard(address(guard));
        vm.warp(block.timestamp + 7 days); vault.applyPriceGuard();
    }

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2); amounts[0] = a; amounts[1] = b;
    }
}
