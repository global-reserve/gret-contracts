// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {MockEligibility} from "../contracts/mocks/MockEligibility.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {
    GRETVaultCase, SenderSurchargeToken, NoOpTransferToken, ShareRoundingToken
} from "./helpers/GRETVaultCase.sol";

/// @dev Model of a token that keeps internal shares and lists each balance as shares times a
/// multiplier, as the xStocks documentation describes for splits: a 4-for-1 split raises the
/// multiplier fourfold, so every balance grows fourfold at once and each unit is worth a quarter.
/// Not a claim about a current component.
contract MultiplierToken {
    uint8 public constant decimals = 18;
    uint256 public multiplier = 1e18;
    mapping(address account => uint256) public sharesOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function balanceOf(address account) public view returns (uint256) {
        return sharesOf[account] * multiplier / 1e18;
    }

    function mint(address to, uint256 amount) external {
        sharesOf[to] += amount * 1e18 / multiplier;
    }

    function setMultiplier(uint256 next) external {
        multiplier = next;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 shares = amount * 1e18 / multiplier;
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}

/// @notice Known limitations (docs/SPECIFICATION.md): each test reproduces the accepted behavior;
/// change it if the decision changes.
contract GRETVaultLimitationsTest is GRETVaultCase {
    /// A donation obstructs retirement, but a transferable, tradable token can be sold.
    function test_donationBlocksRemovalUntilAnotherSale() public {
        _appoint(vault, address(new MockPriceGuard()));
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 2e18, address(faulty), 1, "");
        healthy.mint(address(vault), 11);
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentNotEmpty.selector, address(healthy), 11));
        vault.removeComponent(address(healthy));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentNotEmpty.selector, address(healthy), 11));
        vault.deactivateEmptyComponent(address(healthy));
        vm.stopPrank();
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 11, address(faulty), 1, "");
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
        vault.swap(address(healthy), 2e18, address(faulty), 5e18, "");
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

    /// The guard values one unit of each token at its feed's price, so it cannot see a split applied
    /// through a multiplier before the feed prices the new unit. Gold is worth $4,000 and XS $400,
    /// and the vault holds 10 gold and 100 XS, $40,000 of each. A 4-for-1 split lands while the feed
    /// still shows $400: 100 XS, now worth $10,000, buy all the gold in a swap that looks fair, and
    /// no loss is recorded. Revoking the rebalancer before the split prevents it.
    function test_splitTheFeedHasNotPricedIsNotLimited() public {
        MockERC20 gold = new MockERC20("Gold", "AU", 18);
        MultiplierToken split = new MultiplierToken();
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = gold;
        basket[1] = IERC20(address(split));
        GRETVault target = new GRETVault(basket, _pair(0.01e18, 0.1e18), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : REBALANCER;
            gold.mint(user, 1e24);
            split.mint(user, 1e24);
            vm.startPrank(user);
            gold.approve(address(target), type(uint256).max);
            split.approve(address(target), type(uint256).max);
            vm.stopPrank();
        }
        vm.startPrank(ALICE);
        target.mint(SHARE, ALICE, _pair(0.01e18, 0.1e18), SHARE, 0);
        target.mint(999 * SHARE, ALICE, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.stopPrank();
        MockAggregator goldFeed = new MockAggregator(8, 4000e8);
        MockAggregator splitFeed = new MockAggregator(8, 400e8);
        address[] memory tokens = new address[](2);
        tokens[0] = address(gold);
        tokens[1] = address(split);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](2);
        feeds[0] = IChainlinkFeed(address(goldFeed));
        feeds[1] = IChainlinkFeed(address(splitFeed));
        ChainlinkPriceGuard guard =
            new ChainlinkPriceGuard(address(target), tokens, feeds, _pair(1 days, 1 days));
        _appoint(target, address(guard));
        goldFeed.setAnswer(4000e8);
        splitFeed.setAnswer(400e8);

        // Without a split, 25 XS ($10,000) for all the gold ($40,000) is refused.
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceGuard.SwapLossTooHigh.selector, 40_000e18, 10_000e18)
        );
        vm.prank(REBALANCER);
        target.swap(address(gold), 10e18, address(split), 25e18, "");

        split.setMultiplier(4e18); // the split lands; the feed still prices the old unit
        vm.prank(REBALANCER);
        target.swap(address(gold), 10e18, address(split), 100e18, "");
        assertEq(gold.balanceOf(address(target)), 0);
        assertEq(guard.weeklyLoss(), 0);
        splitFeed.setAnswer(100e8); // the feed catches up
        // The vault held $80,000; it now holds 500 XS at $100.
        assertEq(guard.valueOf(address(split), split.balanceOf(address(target))), 50_000e18);
    }

    /// A token announced for the basket can join and be activated at once. Every exit that does not
    /// skip it then calls it, so a token whose calls revert refuses those exits until the holder
    /// lists it, including exits prepared earlier that listed only other tokens.
    function test_activatedNewcomerRefusesExitsThatDoNotSkipIt() public {
        MockFaultyERC20 joining = new MockFaultyERC20("Joining", "J", 18);
        vm.prank(GOVERNANCE);
        vault.announceComponent(address(joining));
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(address(joining));
        joining.setFault(MockFaultyERC20.Fault.RevertOnBalanceOf);
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(joining));

        address[] memory skipped = new address[](1);
        skipped[0] = address(faulty);
        vm.startPrank(ALICE);
        vm.expectRevert(MockFaultyERC20.BalanceOfBlocked.selector);
        vault.redeem(SHARE, ALICE, new uint256[](0), 0);
        vm.expectRevert(MockFaultyERC20.BalanceOfBlocked.selector);
        vault.redeemSkipping(SHARE, ALICE, new uint256[](0), skipped, 0);
        vm.stopPrank();
        assertEq(vault.balanceOf(ALICE), SHARE);
    }

    /// The notice binds an eligibility contract's address, not its rules: its list can refuse a
    /// holder at once, and a broken contract refuses everyone until governance removes it.
    function test_eligibilityRulesChangeWithoutNotice() public {
        MockEligibility policy = new MockEligibility();
        policy.setListed(ALICE, true);
        vm.prank(GOVERNANCE);
        vault.proposeEligibility(address(policy));
        vm.warp(block.timestamp + 7 days);
        vault.applyEligibility();

        policy.setListed(ALICE, false);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotEligible.selector, ALICE, ALICE));
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);

        policy.setListed(ALICE, true);
        policy.setAnswer(MockEligibility.Answer.Revert);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotEligible.selector, ALICE, ALICE));
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);

        vm.prank(GOVERNANCE);
        vault.removeEligibility();
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
    }

    /// The receipt tolerance is fixed in base units: with only 11 units of F left, one unit short
    /// issues 10/11 of a share, so the minter pays a whole share's H for less than a share.
    function test_shortfallAfterSevereLossOverchargesMinter() public {
        faulty.slash(address(vault), 5e18 - 11);
        faulty.setFault(MockFaultyERC20.Fault.ShortByOneOnTransfer);
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        (uint256 minted,) = vault.mint(SHARE, BOB, _pair(2e18, 11), 0, 0);
        assertEq(minted, 10 * SHARE / 11);
        assertEq(before - healthy.balanceOf(BOB), 2e18);
    }

    /// While a rounding component keeps only a few units, a small mint asks it for one unit, which
    /// moves nothing, and reverts; larger mints still work.
    function test_smallMintRevertsOnNearlyEmptyRoundingComponent() public {
        ShareRoundingToken rounding = new ShareRoundingToken();
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy;
        basket[1] = rounding;
        GRETVault target = new GRETVault(basket, _pair(2e18, 30), GOVERNANCE);
        rounding.mint(ALICE, 1e18);
        rounding.mint(BOB, 1e18);
        vm.prank(ALICE);
        rounding.approve(address(target), type(uint256).max);
        vm.prank(ALICE);
        healthy.approve(address(target), type(uint256).max);
        vm.prank(ALICE);
        target.mint(SHARE, ALICE, _pair(type(uint256).max, type(uint256).max), 0, 0);

        vm.startPrank(BOB);
        rounding.approve(address(target), type(uint256).max);
        healthy.approve(address(target), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.UnexpectedBalance.selector, 1, 1, 0));
        target.mint(SHARE / 30, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        target.mint(SHARE, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.stopPrank();
    }

    /// Basket changes do not update the initial amounts: after a rotation into a component that
    /// joined without one, a restart from zero supply reverts until governance sets them.
    function test_rotationLeavesNoInitialAmountForRestart() public {
        MockERC20 next = new MockERC20("Next", "N", 18);
        vm.prank(GOVERNANCE);
        vault.announceComponent(address(next));
        _appoint(vault, address(new MockPriceGuard()));
        vault.addComponent(address(next));
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(next));
        next.mint(REBALANCER, 2e18);
        vm.startPrank(REBALANCER);
        next.approve(address(vault), type(uint256).max);
        vault.swap(address(healthy), 2e18, address(next), 1e18, "");
        vault.swap(address(faulty), 5e18, address(next), 1e18, "");
        vm.stopPrank();
        vm.startPrank(GOVERNANCE);
        vault.removeComponent(address(healthy));
        vault.removeComponent(address(faulty));
        vm.stopPrank();
        assertEq(vault.initialAmounts()[0], 0);
        uint256 version = vault.basketVersion();
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _one(0), version);

        next.mint(BOB, 1e18);
        vm.startPrank(BOB);
        next.approve(address(vault), type(uint256).max);
        vm.expectRevert(GRETVault.EmptyBasket.selector);
        vault.mint(SHARE, BOB, _one(type(uint256).max), 0, version);
        vm.stopPrank();
        vm.prank(GOVERNANCE);
        vault.setInitialAmounts(_one(1e18), version);
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _one(type(uint256).max), 0, version);
        assertEq(vault.balanceOf(BOB), SHARE);
    }

    /// An entry before a future donation still shares that donation.
    function test_entryBeforeFutureDonationStillSharesIt() public {
        uint256 before = healthy.balanceOf(BOB);
        vm.prank(BOB);
        vault.mint(99 * SHARE, BOB, _pair(198e18, 495e18), 99 * SHARE, 0);
        healthy.mint(address(vault), 100e18);
        vm.prank(BOB);
        vault.redeem(99 * SHARE, BOB, _pair(0, 0), 0);
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
        vault.mint(9 * SHARE, CAROL, _pair(type(uint256).max, type(uint256).max), 0, 0); // pays no faulty at all
        vm.stopPrank();

        faulty.setFault(MockFaultyERC20.Fault.None);
        vm.prank(GOVERNANCE);
        vault.activateComponent(address(faulty));
        vm.prank(CAROL);
        vault.redeem(9 * SHARE, CAROL, _pair(0, 0), 0);
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
        (uint256 dust,) = vault.mint(1e12, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        assertGt(dust, 0);
        assertLt(dust, SHARE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, dust));
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);

        // Alice can redeem only the tiny excess over MIN_SUPPLY without cooperation.
        vm.prank(ALICE);
        vault.redeem(dust, ALICE, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), SHARE);
        assertEq(vault.balanceOf(ALICE), SHARE - dust);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, SHARE - dust));
        vm.prank(ALICE);
        vault.redeem(dust, ALICE, _pair(0, 0), 0);
    }

    /// Fee GRET below 1 GRET held by the recipient keeps the last holder from leaving in full,
    /// even after both fees are cut to zero, until the recipient hands it over.
    function test_feeRecipientHoldsBackLastHolder() public {
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
        vm.startPrank(GOVERNANCE);
        vault.setFeeRecipient(CAROL);
        vault.proposeFees(0, 500);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vault.applyFees();
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
        vm.prank(GOVERNANCE);
        vault.proposeFees(0, 0);

        vm.expectRevert(abi.encodeWithSelector(GRETVault.SupplyBelowMinimum.selector, 5e16));
        vm.prank(BOB);
        vault.redeem(SHARE, BOB, _pair(0, 0), 0);
        vm.prank(CAROL);
        vault.transfer(BOB, 5e16);
        vm.prank(BOB);
        vault.redeem(SHARE + 5e16, BOB, _pair(0, 0), 0);
        assertEq(vault.totalSupply(), 0);
    }

    /// Redemption minima apply to the amounts sent, not to what arrives.
    function test_redeemMinimumIgnoresRecipientFee() public {
        faulty.setFault(MockFaultyERC20.Fault.FeeOnTransfer);
        uint256 before = faulty.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256[] memory reported = vault.redeem(SHARE, ALICE, _pair(2e18, 5e18), 0);
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
        assertEq(single.consumedRights(ALICE, 0), 100e18);
        assertEq(single.pendingRights(ALICE, 0), 50e18); // Undelivered tokens are automatically reallocated.
    }

    /// A surcharge the token takes from the sender comes out of the remaining holders'
    /// backing, unlike in a rescue.
    function test_senderSurchargeComesOutOfRemainingBacking() public {
        SenderSurchargeToken token = new SenderSurchargeToken();
        GRETVault single = _single(token, 100e18);
        token.enable();
        vm.prank(ALICE);
        single.redeem(SHARE, ALICE, _one(100e18), 0);
        assertEq(single.reserves()[0], 99e18);
        assertEq(token.balanceOf(address(single)), 99e18);
        // The last transfer now needs more than the entire balance.
        vm.expectRevert();
        vm.prank(BOB);
        single.redeem(SHARE, BOB, _one(0), 0);
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
        vault.mint(1e9, BOB, _pair(type(uint256).max, type(uint256).max), 0, 0);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), whole, address(faulty), 1, "");
        assertGt(vault.reserves()[0], 0);
        vm.expectRevert(
            abi.encodeWithSelector(GRETVault.ComponentNotEmpty.selector, address(healthy), vault.reserves()[0])
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
            single.mint(SHARE, user, _one(1), SHARE, 0);
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
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);
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
        vault.mint(k * SHARE, BOB, _pair(2e18 * k, 5e18 * k), k * SHARE, 0);
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
