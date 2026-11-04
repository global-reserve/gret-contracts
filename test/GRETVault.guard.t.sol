// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";
import {IPriceGuard} from "../contracts/IPriceGuard.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";
import {GRETVaultCase} from "./helpers/GRETVaultCase.sol";

/// @dev Models an in-place issuer upgrade that changes decimals and rescales balances, keeping value.
contract RedenominatingToken is ERC20 {
    uint8 private _current;

    constructor(uint8 decimals_) ERC20("Redenominating", "RD") {
        _current = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _current;
    }

    function redenominate(uint8 next, address[] calldata accounts) external {
        uint8 previous = _current;
        for (uint256 i; i < accounts.length; ++i) {
            uint256 balance = balanceOf(accounts[i]);
            uint256 scaled =
                next < previous ? balance / 10 ** (previous - next) : balance * 10 ** (next - previous);
            _burn(accounts[i], balance);
            _mint(accounts[i], scaled);
        }
        _current = next;
    }
}

/// @dev An issuer freeze that only stops an account from sending (USDT-style blacklist on the sender).
contract SenderFreezeToken is MockERC20 {
    mapping(address account => bool) public frozenSender;

    error SenderFrozen(address account);

    constructor() MockERC20("SenderFreeze", "SF", 18) {}

    function freezeSender(address account) external {
        frozenSender[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && frozenSender[from]) revert SenderFrozen(from);
        super._update(from, to, value);
    }
}

/// @dev A guard with an owner: during the notice it forwards to a ChainlinkPriceGuard; later the owner
/// can switch it to accept everything, with no new notice in the vault.
contract SwitchableGuard is IPriceGuard {
    address public immutable owner;
    address public immutable vault;
    IPriceGuard public inner;
    bool public acceptAll;

    constructor(address vault_) {
        owner = msg.sender;
        vault = vault_;
    }

    function setInner(IPriceGuard inner_) external {
        require(msg.sender == owner);
        inner = inner_;
    }

    function setAcceptAll(bool value) external {
        require(msg.sender == owner);
        acceptAll = value;
    }

    function checkSwap(address sell, uint256 sellAmount, address buy, uint256 received) external {
        require(msg.sender == vault);
        if (acceptAll) return;
        inner.checkSwap(sell, sellAmount, buy, received);
    }

    // The inner ChainlinkPriceGuard values "its vault" (this contract) through these views.
    function components() external view returns (IERC20[] memory) {
        return GRETVault(vault).components();
    }

    function reserves() external view returns (uint256[] memory) {
        return GRETVault(vault).reserves();
    }
}

contract GRETVaultGuardTest is GRETVaultCase {
    uint256 internal constant W = 7 days;
    MockAggregator internal hFeed;
    MockAggregator internal fFeed;

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _feeds() internal {
        hFeed = new MockAggregator(8, 100e8);
        fFeed = new MockAggregator(8, 40e8);
    }

    function _refresh() internal {
        hFeed.setAnswer(100e8);
        fFeed.setAnswer(40e8);
    }

    function _guardFor(GRETVault target, address a, address b, MockAggregator fa, MockAggregator fb)
        internal
        returns (ChainlinkPriceGuard)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = a;
        tokens[1] = b;
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](2);
        feeds[0] = IChainlinkFeed(address(fa));
        feeds[1] = IChainlinkFeed(address(fb));
        return new ChainlinkPriceGuard(address(target), tokens, feeds, _pair(1 days, 1 days));
    }

    function _guard() internal returns (ChainlinkPriceGuard) {
        return _guardFor(vault, address(healthy), address(faulty), hFeed, fFeed);
    }

    /// @dev Value of the vault's reserves (all of Alice's GRET) at the feed prices, USD 1e18.
    function _usd(ChainlinkPriceGuard pricer) internal view returns (uint256) {
        uint256[] memory r = vault.reserves();
        return pricer.valueOf(address(healthy), r[0]) + pricer.valueOf(address(faulty), r[1]);
    }

    /// @dev Hostile rebalancer: alternating swaps, each losing 1.99% of what it sells at the feed
    /// prices, halving the size whenever the weekly limit refuses, until the budget is used up.
    function _drain(ChainlinkPriceGuard guard) internal returns (uint256 accepted) {
        uint256 dir = vault.reserves()[0] > 0 ? 0 : 1;
        uint256 shift;
        vm.startPrank(REBALANCER);
        while (shift < 30) {
            (address sold, address bought) =
                dir == 0 ? (address(healthy), address(faulty)) : (address(faulty), address(healthy));
            uint256 amount = vault.reserves()[dir] >> shift;
            if (amount == 0) break;
            uint256 received = guard.valueOf(sold, amount) * 9801 / 10_000 * 1e18 / guard.valueOf(bought, 1e18);
            try vault.swap(sold, amount, bought, received) {
                ++accepted;
                dir ^= 1;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), ChainlinkPriceGuard.WeeklyLossTooHigh.selector);
                ++shift;
            }
        }
        vm.stopPrank();
    }

    function _bps(uint256 before, uint256 afterValue) internal pure returns (uint256) {
        return (before - afterValue) * 10_000 / before;
    }

    /// @dev A vault of two tokens in which Alice minted 1 GRET; Alice, Bob and the rebalancer hold
    /// both tokens and approved the vault.
    function _twoTokenVault(MockERC20 a, MockERC20 b, uint256 amountA, uint256 amountB)
        internal
        returns (GRETVault target)
    {
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = a;
        basket[1] = b;
        target = new GRETVault(basket, _pair(amountA, amountB), GOVERNANCE);
        for (uint256 i; i < 3; ++i) {
            address user = i == 0 ? ALICE : i == 1 ? BOB : REBALANCER;
            a.mint(user, amountA * 1000);
            b.mint(user, amountB * 1000);
            vm.startPrank(user);
            a.approve(address(target), type(uint256).max);
            b.approve(address(target), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(ALICE);
        target.mint(SHARE, _pair(amountA, amountB), SHARE, 0);
    }

    // ------------------------------------------------------------------------------------------
    // A replacement guard continues the replaced guard's weekly count
    // ------------------------------------------------------------------------------------------

    /// @dev One swap that sells 1 H and loses 1.99% of it at the feed prices.
    function _smallLoss(ChainlinkPriceGuard guard) internal {
        uint256 received = guard.valueOf(address(healthy), 1e18) * 9801 / 10_000 * 1e18
            / guard.valueOf(address(faulty), 1e18);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 1e18, address(faulty), received);
    }

    /// Control: one guard, one fixed week.
    function test_singleGuardOneWeek() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W + 1 hours);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a));
        _refresh();
        uint256 v0 = _usd(a);
        _drain(a);
        uint256 v1 = _usd(a);
        assertLe(_bps(v0, v1), 199);
    }

    /// Control: one guard, across the change of week (documented 4% in a row).
    function test_singleGuardAcrossWeekChange() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a)); // now exactly at a week boundary S
        vm.warp(block.timestamp + W - 120);
        _refresh();
        uint256 v0 = _usd(a);
        _drain(a);
        vm.warp(block.timestamp + 180);
        _refresh();
        _drain(a);
        uint256 v1 = _usd(a);
        assertLe(_bps(v0, v1), 396);
    }

    /// B's first loss in the week starts from what A recorded in that week.
    function test_replacementContinuesWeeklyCount() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W + 1 hours);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a));
        ChainlinkPriceGuard b = _guard();
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(b));
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        _smallLoss(a);
        uint256 fromA = a.weeklyLoss();
        assertGt(fromA, 0);
        vault.applyPriceGuard();
        assertEq(vault.previousPriceGuard(), address(a));
        _smallLoss(b);
        // Two similar losses: B's count holds both, not only its own.
        assertGt(b.weeklyLoss(), fromA * 19 / 10);
        assertLe(b.weeklyLoss(), fromA * 21 / 10);
        assertEq(b.currentWeek(), a.currentWeek());
    }

    /// The rebalancer drains guard A, applies the ready replacement B itself and drains B, in the
    /// same block and fixed week: together they stay within one weekly budget.
    function test_replacementInSameWeekSharesOneBudget() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W + 1 hours);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a));
        ChainlinkPriceGuard b = _guard(); // honest, identical configuration
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(b));
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        uint256 week = block.timestamp / W;

        uint256 v0 = _usd(a);
        _drain(a);
        vm.prank(REBALANCER); // anyone may apply
        vault.applyPriceGuard();
        assertEq(address(vault.priceGuard()), address(b));
        _drain(b);
        uint256 v1 = _usd(a);
        assertEq(block.timestamp / W, week);
        assertLe(_bps(v0, v1), 199);

        // A second replacement can never become ready in the same fixed week.
        ChainlinkPriceGuard c = _guard();
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(c));
        assertGt(vault.pendingPriceGuardReadyAt() / W, week);
    }

    /// A and B at the end of week N, then B at the start of N+1: two budgets, as with one guard
    /// across the change of week.
    function test_replacementAcrossWeekChangeKeepsTwoBudgets() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a)); // at a week boundary S
        ChainlinkPriceGuard b = _guard();
        vm.warp(block.timestamp + W - 120);
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(b)); // ready 120 s before the boundary S + 2W
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        uint256 start = block.timestamp;
        uint256 v0 = _usd(a);
        _drain(a);
        vm.prank(REBALANCER);
        vault.applyPriceGuard();
        _drain(b);
        uint256 v1 = _usd(a);
        assertLe(_bps(v0, v1), 199);
        vm.warp(block.timestamp + 180);
        _refresh();
        _drain(b);
        uint256 v2 = _usd(a);
        assertEq(block.timestamp - start, 180);
        // Cap with two budgets: 1 - 0.98^2 = 3.96%.
        assertLe(v0 - v2, v0 * 396 / 10_000 + 1);
    }

    /// Back-to-back replacements (C proposed in the block B is applied): a closed 7-day window
    /// covers A and B in week N and B and C in week N+1, still two budgets.
    function test_chainedReplacementsKeepTwoBudgetsInSevenDays() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W);
        ChainlinkPriceGuard a = _guard();
        _appoint(vault, address(a));
        ChainlinkPriceGuard b = _guard();
        vm.warp(block.timestamp + W - 120);
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(b));
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        uint256 start = block.timestamp;
        uint256 v0 = _usd(a);
        _drain(a);
        vault.applyPriceGuard();
        ChainlinkPriceGuard c = _guard();
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(c));
        _drain(b);
        vm.warp(block.timestamp + 180);
        _refresh();
        _drain(b);
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        assertEq(block.timestamp / W, (start + 180) / W); // still week N+1
        vault.applyPriceGuard();
        _drain(c);
        uint256 v1 = _usd(a);
        assertEq(block.timestamp - start, 7 days);
        assertLe(v0 - v1, v0 * 396 / 10_000 + 1);
    }

    /// A predecessor that keeps no weekly count, such as an accept-all guard, counts as zero.
    function test_replacementOfAnotherKindOfGuardStartsAtZero() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W + 1 hours);
        _appoint(vault, address(new MockPriceGuard()));
        ChainlinkPriceGuard b = _guard();
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(address(b));
        vm.warp(vault.pendingPriceGuardReadyAt());
        _refresh();
        vault.applyPriceGuard();
        _smallLoss(b);
        uint256 own = b.weeklyLoss();
        assertGt(own, 0);
        assertLt(own, 1e16);
        _smallLoss(b);
        assertGt(b.weeklyLoss(), own);
    }

    // ------------------------------------------------------------------------------------------
    // Token decimals are read once, at deployment
    // ------------------------------------------------------------------------------------------

    function test_decimalsDownLetsReserveGoForDust() public {
        MockERC20 h = new MockERC20("H", "H", 18);
        RedenominatingToken r = new RedenominatingToken(18);
        GRETVault target = _twoTokenVault(h, MockERC20(address(r)), 2e18, 5e18);
        MockAggregator hf = new MockAggregator(8, 100e8);
        MockAggregator rf = new MockAggregator(8, 40e8);
        ChainlinkPriceGuard g = _guardFor(target, address(h), address(r), hf, rf);
        _appoint(target, address(g));
        hf.setAnswer(100e8);
        rf.setAnswer(40e8);

        address[] memory holders = new address[](3);
        holders[0] = address(target);
        holders[1] = REBALANCER;
        holders[2] = ALICE;
        r.redenominate(6, holders); // value kept: 5e6 units of 6 decimals are still 5 R ($200)
        assertEq(r.balanceOf(address(target)), 5e6);
        assertEq(g.valueOf(address(r), 5e6), 2e8); // $2e-10 instead of $200

        uint256 rBefore = r.balanceOf(REBALANCER);
        vm.prank(REBALANCER);
        target.swap(address(r), 5e6, address(h), 2e6);
        assertEq(r.balanceOf(REBALANCER) - rBefore, 5e6); // 5 whole R, $200
        assertEq(target.reserves()[1], 0);
        assertEq(target.reserves()[0], 2e18 + 2e6);
        assertEq(g.weeklyLoss(), 0);
    }

    function test_decimalsUpLetsOtherReservesGoForDust() public {
        MockERC20 h = new MockERC20("H", "H", 18);
        RedenominatingToken u = new RedenominatingToken(6);
        GRETVault target = _twoTokenVault(h, MockERC20(address(u)), 2e18, 5e6);
        MockAggregator hf = new MockAggregator(8, 100e8);
        MockAggregator uf = new MockAggregator(8, 40e8);
        ChainlinkPriceGuard g = _guardFor(target, address(h), address(u), hf, uf);
        _appoint(target, address(g));
        hf.setAnswer(100e8);
        uf.setAnswer(40e8);

        address[] memory holders = new address[](3);
        holders[0] = address(target);
        holders[1] = REBALANCER;
        holders[2] = ALICE;
        u.redenominate(18, holders);
        assertEq(u.balanceOf(address(target)), 5e18);

        uint256 hBefore = h.balanceOf(REBALANCER);
        vm.prank(REBALANCER);
        target.swap(address(h), 2e18, address(u), 5e6); // 5e6 units = 5e-12 U now
        assertEq(h.balanceOf(REBALANCER) - hBefore, 2e18); // all of H, $200
        assertEq(target.reserves()[0], 0);
        assertEq(g.weeklyLoss(), 0);
    }

    // ------------------------------------------------------------------------------------------
    // A written-off component cannot be bought back
    // ------------------------------------------------------------------------------------------

    function _writtenOffSetup()
        internal
        returns (GRETVault target, MockERC20 h, SenderFreezeToken s, ChainlinkPriceGuard g)
    {
        h = new MockERC20("H", "H", 18);
        s = new SenderFreezeToken();
        target = _twoTokenVault(h, s, 2e18, 5e18);
        vm.prank(BOB);
        target.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
        hFeed = new MockAggregator(8, 100e8);
        fFeed = new MockAggregator(8, 40e8);
        g = _guardFor(target, address(h), address(s), hFeed, fFeed);
        _appoint(target, address(g));
        s.freezeSender(address(target)); // the vault can still receive S, not send it
        vm.prank(GOVERNANCE);
        target.proposeWriteOff(address(s));
        vm.warp(block.timestamp + 7 days);
        target.writeOffComponent(address(s));
        _refresh();
        assertEq(target.reserves()[1], 0);
        assertTrue(target.writtenOff(address(s)));
    }

    function test_writtenOffComponentCannotBeBoughtAtFeedPrice() public {
        (GRETVault target, MockERC20 h, SenderFreezeToken s, ChainlinkPriceGuard g) = _writtenOffSetup();
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentExcluded.selector, address(s)));
        vm.prank(REBALANCER);
        target.swap(address(h), 4e18, address(s), 10e18);
        assertEq(g.weeklyLoss(), 0);
        assertEq(target.reserves()[0], 4e18);
        assertEq(target.reserves()[1], 0);
    }

    function test_threeWeiPurchaseCannotUndoWriteOff() public {
        (GRETVault target, MockERC20 h, SenderFreezeToken s,) = _writtenOffSetup();
        vm.expectRevert(abi.encodeWithSelector(GRETVault.ComponentExcluded.selector, address(s)));
        vm.prank(REBALANCER);
        target.swap(address(h), 1, address(s), 3);
        uint256 version = target.basketVersion();
        vm.prank(ALICE);
        uint256[] memory paid = target.redeem(SHARE, _pair(0, 0), version);
        assertEq(paid[0], 2e18);
        assertEq(paid[1], 0);
    }

    // ------------------------------------------------------------------------------------------
    // A feed that lags the market adds its error to the guard's limits
    // ------------------------------------------------------------------------------------------

    function test_laggingFeedLossIsOnTopOfTheWeeklyLimit() public {
        _feeds();
        vm.warp((block.timestamp / W + 1) * W + 1 hours);
        ChainlinkPriceGuard g = _guard();
        _appoint(vault, address(g));
        _refresh();

        // 1. Accurate feeds: the rebalancer uses the whole weekly budget.
        uint256 v0 = _usd(g);
        _drain(g);
        uint256 v1 = _usd(g);
        uint256 recorded = g.weeklyLoss();
        uint256 recordedLoss = v0 - v1;

        // 2. F's market falls 1.9% below its last report, inside a 2% deviation threshold: no update.
        //    The vault buys all F it can at the feed price (exactly fair at the feed).
        uint256 hSold = vault.reserves()[0];
        uint256 fBought = (hSold * 5 + 1) / 2;
        vm.prank(REBALANCER);
        vault.swap(address(healthy), hSold, address(faulty), fBought);
        // Rebalancer's gain at market prices: H at $100, F at $39.24.
        uint256 gain1 = hSold * 100 - fBought * 3924 / 100;

        // 3. F's market rises to 1.9% above the same report: the vault sells F at the feed price.
        uint256 fSold = vault.reserves()[1] / 2;
        uint256 hBought = (fSold * 2 + 4) / 5;
        vm.prank(REBALANCER);
        vault.swap(address(faulty), fSold, address(healthy), hBought);
        uint256 gain2 = fSold * 4076 / 100 - hBought * 100;

        assertEq(g.weeklyLoss(), recorded); // nothing recorded, even with the budget exhausted
        uint256 total = recordedLoss + gain1 + gain2;
        assertGt(total * 10_000 / v0, 300);
    }

    /// One swap inside the per-swap limit at the feed loses about 3.9% of the value sold at market
    /// prices when the bought token's feed is 1.9% above its market.
    function test_perSwapLimitAtMarketPrices() public {
        _feeds();
        ChainlinkPriceGuard g = _guard();
        _appoint(vault, address(g));
        _refresh();
        uint256 sold = 1e18; // $100 of H
        uint256 received = g.valueOf(address(healthy), sold) * 9801 / 10_000 * 1e18 / g.valueOf(address(faulty), 1e18);
        vm.prank(REBALANCER);
        vault.swap(address(healthy), sold, address(faulty), received);
        uint256 marketReceived = received * 3924 / 100; // F at $39.24
        uint256 lossBpsMarket = (sold * 100 - marketReceived) * 10_000 / (sold * 100);
        assertGt(lossBpsMarket, 380);
    }

    // ------------------------------------------------------------------------------------------
    // The notice binds an address, not behavior; the vault and EIP-7702 accounts are refused
    // ------------------------------------------------------------------------------------------

    function test_switchableGuardLoosensAfterNotice() public {
        _feeds();
        SwitchableGuard sw = new SwitchableGuard(address(vault));
        ChainlinkPriceGuard inner = _guardFor(GRETVault(address(sw)), address(healthy), address(faulty), hFeed, fFeed);
        sw.setInner(inner);
        _appoint(vault, address(sw));
        _refresh();
        // During and right after the notice it behaves like ChainlinkPriceGuard.
        vm.prank(REBALANCER);
        vm.expectPartialRevert(ChainlinkPriceGuard.SwapLossTooHigh.selector);
        vault.swap(address(healthy), 2e18, address(faulty), 1);
        // Later the owner flips it; the vault sees no proposal and no notice.
        sw.setAcceptAll(true);
        assertEq(vault.pendingPriceGuard(), address(0));
        vm.prank(REBALANCER);
        vault.swap(address(healthy), 2e18, address(faulty), 1);
        assertEq(vault.reserves()[0], 0);
    }

    /// An EIP-7702 account can replace its code without notice: it is refused as a guard and as a
    /// component.
    function test_delegatedAccountIsRefused() public {
        address eoa = address(0x7702);
        // Hardhat does not support signAndAttachDelegation: write the EIP-7702 designator directly.
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(new MockPriceGuard())));
        assertEq(eoa.code.length, 23);
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, eoa));
        vault.proposePriceGuard(eoa);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, eoa));
        vault.announceComponent(eoa);
        vm.stopPrank();
        assertEq(vault.pendingPriceGuard(), address(0));
        assertEq(vault.componentReadyAt(eoa), 0);
    }

    /// The vault is refused as its own guard and as its own component.
    function test_vaultItselfIsRefused() public {
        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, address(vault)));
        vault.proposePriceGuard(address(vault));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, address(vault)));
        vault.announceComponent(address(vault));
        vm.stopPrank();
    }

    /// Another 23-byte contract that is not a delegation designator is accepted.
    function test_shortContractThatIsNotADesignatorIsAccepted() public {
        address other = address(0x2323);
        vm.etch(other, abi.encodePacked(hex"ef0200", address(0xBEEF)));
        vm.prank(GOVERNANCE);
        vault.proposePriceGuard(other);
        assertEq(vault.pendingPriceGuard(), other);
    }
}
