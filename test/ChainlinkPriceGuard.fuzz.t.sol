// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChainlinkPriceGuard, IChainlinkFeed} from "../contracts/ChainlinkPriceGuard.sol";
import {GRETVault} from "../contracts/GRETVault.sol";
import {MockAggregator} from "../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @notice Whatever swaps a rebalancer attempts within a week, at any size and price, and whatever
/// is minted and redeemed in between, a holder who stays keeps at least 98% of the value of their
/// GRET at fixed prices.
contract ChainlinkPriceGuardFuzzTest is Test {
    address internal constant GOVERNANCE = address(0x60F);
    address internal constant REBALANCER = address(0x5EB);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant FEES = address(0xFEE);
    /// @dev Room for rounding: each of three reserves is valued rounded down.
    uint256 internal constant TOLERANCE = 10;

    MockERC20[3] internal tokens;
    MockAggregator[3] internal feeds;
    int256[3] internal prices = [int256(100e8), int256(80_000e8), int256(1e8)];
    GRETVault internal vault;
    ChainlinkPriceGuard internal guard;

    function setUp() public {
        tokens[0] = new MockERC20("Mock A", "MA", 18);
        tokens[1] = new MockERC20("Mock B", "MB", 8);
        tokens[2] = new MockERC20("Mock C", "MC", 6);
        IERC20[] memory components = new IERC20[](3);
        address[] memory priced = new address[](3);
        IChainlinkFeed[] memory sources = new IChainlinkFeed[](3);
        uint256[] memory maxAges = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            feeds[i] = new MockAggregator(8, prices[i]);
            components[i] = IERC20(address(tokens[i]));
            priced[i] = address(tokens[i]);
            sources[i] = IChainlinkFeed(address(feeds[i]));
            maxAges[i] = 1 days;
        }
        uint256[] memory initialAmounts = new uint256[](3);
        initialAmounts[0] = 2e18;
        initialAmounts[1] = 1e5;
        initialAmounts[2] = 50e6;
        vault = new GRETVault(components, initialAmounts, GOVERNANCE);
        guard = new ChainlinkPriceGuard(address(vault), priced, sources, maxAges);

        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 3; ++k) {
                address user = k == 0 ? ALICE : k == 1 ? BOB : REBALANCER;
                tokens[i].mint(user, 1e40);
                vm.prank(user);
                tokens[i].approve(address(vault), type(uint256).max);
            }
        }
        vm.startPrank(ALICE);
        vault.mint(1e18, _noMax(), 0, 0);
        vault.mint(99e18, _noMax(), 0, 0);
        vm.stopPrank();

        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(guard));
        vault.setFeeRecipient(FEES);
        vault.proposeFees(50, 50);
        vm.stopPrank();
        // The clock stands still during a test, so every swap below falls in the same week.
        vm.warp(block.timestamp + 7 days);
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
        vault.applyFees();
        for (uint256 i; i < 3; ++i) {
            feeds[i].setAnswer(prices[i]);
        }
    }

    function testFuzz_weeklyLossStaysWithinTwoPercent(uint256 seed, uint256 steps) public {
        steps = bound(steps, 1, 40);
        uint256 valueBefore = _aliceValue();
        for (uint256 step; step < steps; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = (r >> 64) % 4;
            if (action == 0) {
                // Up to 100 times Alice's position arrives, as a temporary deposit would.
                uint256 shares = vault.balanceOf(ALICE) * (1 + (r >> 72) % 10_000) / 100;
                uint256 version = vault.basketVersion();
                vm.prank(BOB);
                vault.mint(shares, _noMax(), 0, version);
                continue;
            }
            if (action == 1) {
                uint256 shares = vault.balanceOf(BOB) * (1 + (r >> 72) % 100) / 100;
                if (shares == 0) continue;
                uint256 version = vault.basketVersion();
                vm.prank(BOB);
                vault.redeem(shares, new uint256[](3), version);
                continue;
            }
            uint256 sell = r % 3;
            uint256 buy = (sell + 1 + (r >> 8) % 2) % 3;
            uint256 reserve = vault.reserves()[sell];
            if (reserve == 0) continue;
            uint256 sellAmount = reserve * (1 + (r >> 16) % 100) / 100;
            if (sellAmount == 0) sellAmount = 1;
            // From a 1% gain to a 3% loss on what the vault sells.
            uint256 keptBps = 9_700 + (r >> 32) % 401;
            uint256 targetValue = guard.valueOf(address(tokens[sell]), sellAmount) * keptBps / 10_000;
            uint256 buyAmount = targetValue * 10 ** tokens[buy].decimals()
                / guard.valueOf(address(tokens[buy]), 10 ** tokens[buy].decimals());
            if (buyAmount == 0) continue;
            vm.prank(REBALANCER);
            try vault.swap(address(tokens[sell]), sellAmount, address(tokens[buy]), buyAmount) {} catch {}
        }
        assertLe(guard.weeklyLoss(), 2e16);
        assertGe(_aliceValue() + TOLERANCE, valueBefore * 9_800 / 10_000);
    }

    /// @dev What Alice's GRET is worth at the fixed prices.
    function _aliceValue() internal view returns (uint256 total) {
        uint256[] memory reserves = vault.reserves();
        for (uint256 i; i < 3; ++i) {
            total += guard.valueOf(address(tokens[i]), reserves[i]);
        }
        return total * vault.balanceOf(ALICE) / vault.totalSupply();
    }

    function _noMax() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = type(uint256).max;
        }
    }
}
