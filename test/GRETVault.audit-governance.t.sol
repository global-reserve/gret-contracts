// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";

/// @notice Audit regression: removing any position must preserve token-address accounting.
/// @dev The permissive guard isolates basket bookkeeping; this does not test swap pricing or
/// compatibility with the real issuers. The expected ledger never reads the vault's reserves.
contract GRETVaultAuditGovernanceTest is Test {
    address private constant GOVERNANCE = address(0x60F);
    address private constant REBALANCER = address(0x5EB);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SHARE = 1e18;

    GRETVault private vault;
    address[] private order;
    mapping(address token => uint256) private expectedReserve;
    mapping(address token => uint256) private expectedInitial;

    function setUp() public {
        IERC20[] memory basket = new IERC20[](4);
        uint256[] memory initial = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            MockERC20 token = new MockERC20("Audit component", "AC", 18);
            basket[i] = token;
            order.push(address(token));
            initial[i] = (i + 1) * SHARE;
            expectedInitial[address(token)] = initial[i];
            expectedReserve[address(token)] = initial[i];
        }
        vault = new GRETVault(basket, initial, GOVERNANCE);
        for (uint256 i; i < 4; ++i) {
            MockERC20 token = MockERC20(order[i]);
            for (uint256 j; j < 3; ++j) {
                address user = j == 0 ? ALICE : j == 1 ? BOB : REBALANCER;
                token.mint(user, 1e30);
                vm.prank(user);
                token.approve(address(vault), type(uint256).max);
            }
        }
        vm.prank(ALICE);
        vault.mint(SHARE, initial, SHARE, 0);
        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(new MockPriceGuard()));
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
    }

    function testFuzz_shiftedIndicesPreserveAddressLedger(uint256 seed, uint256 rounds) public {
        rounds = bound(rounds, 3, 9);
        for (uint256 step; step < rounds; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            // Every case includes a first, middle and last removal; later positions are random.
            uint256 index = step == 0 ? 0 : step == 1 ? 1 + random % 2 : step == 2 ? 3 : random % 4;
            _rotate(index, random);
            _mintAndRedeem(SHARE + (random >> 64) % (2 * SHARE));
        }
        _restartWithReorderedInitialAmounts();
    }

    function _rotate(uint256 index, uint256 random) private {
        address sold = order[index];
        address bought = order[(index + 1 + (random >> 8) % 3) % 4];
        uint256 buyAmount = 1e12 + (random >> 128) % 1e12;
        uint256 oldVersion = vault.basketVersion();
        vm.prank(REBALANCER);
        vault.swap(sold, expectedReserve[sold], bought, buyAmount);
        expectedReserve[sold] = 0;
        expectedReserve[bought] += buyAmount;

        vm.prank(GOVERNANCE);
        vault.removeComponent(sold);
        for (uint256 i = index; i + 1 < order.length; ++i) order[i] = order[i + 1];
        order.pop();
        _assertAccounting();
        assertEq(vault.basketVersion(), oldVersion + 1);

        // The mapping must point to the shifted position, not to the removed token's old slot.
        uint256 donation = 100 + random % 100;
        MockERC20(bought).mint(address(vault), donation);
        vm.prank(GOVERNANCE);
        vault.sync(bought);
        expectedReserve[bought] += donation;
        _assertAccounting();

        vm.prank(GOVERNANCE);
        vault.announceComponent(sold);
        vm.warp(block.timestamp + 7 days);
        vault.addComponent(sold);
        order.push(sold);
        expectedInitial[sold] = 0;
        assertEq(vault.basketVersion(), oldVersion + 2);
        _assertAccounting();

        // Restoring the same length must not make previously prepared positional calls valid.
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BasketChanged.selector, oldVersion, oldVersion + 2));
        vm.prank(BOB);
        vault.mint(SHARE, new uint256[](4), 0, oldVersion);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.BasketChanged.selector, oldVersion, oldVersion + 2));
        vm.prank(ALICE);
        vault.redeem(SHARE, new uint256[](4), oldVersion);

        // Give the re-added token a distinct reserve, so later removals exercise every position.
        MockERC20(sold).mint(address(vault), donation * 1e10);
        vm.prank(GOVERNANCE);
        vault.sync(sold);
        expectedReserve[sold] = donation * 1e10;
        _assertAccounting();
    }

    function _mintAndRedeem(uint256 shares) private {
        uint256 supply = vault.totalSupply();
        uint256 version = vault.basketVersion();
        uint256[] memory inputs = new uint256[](order.length);
        for (uint256 i; i < order.length; ++i) {
            uint256 product = shares * expectedReserve[order[i]];
            inputs[i] = product / supply + (product % supply == 0 ? 0 : 1);
        }
        vm.prank(BOB);
        (uint256 minted, uint256[] memory received) = vault.mint(shares, inputs, shares, version);
        assertEq(minted, shares);
        for (uint256 i; i < order.length; ++i) {
            assertEq(received[i], inputs[i]);
            expectedReserve[order[i]] += inputs[i];
        }
        _assertAccounting();

        uint256[] memory outputs = new uint256[](order.length);
        uint256[] memory balancesBefore = new uint256[](order.length);
        for (uint256 i; i < order.length; ++i) {
            outputs[i] = shares * expectedReserve[order[i]] / (supply + shares);
            balancesBefore[i] = IERC20(order[i]).balanceOf(BOB);
        }
        vm.prank(BOB);
        uint256[] memory paid = vault.redeem(shares, outputs, version);
        for (uint256 i; i < order.length; ++i) {
            assertEq(paid[i], outputs[i]);
            assertEq(IERC20(order[i]).balanceOf(BOB) - balancesBefore[i], outputs[i]);
            expectedReserve[order[i]] -= outputs[i];
        }
        assertEq(vault.totalSupply(), supply);
        _assertAccounting();
    }

    function _restartWithReorderedInitialAmounts() private {
        uint256 version = vault.basketVersion();
        vm.prank(ALICE);
        vault.redeem(SHARE, new uint256[](order.length), version);
        for (uint256 i; i < order.length; ++i) expectedReserve[order[i]] = 0;
        _assertAccounting();
        assertEq(vault.totalSupply(), 0);

        uint256[] memory initial = new uint256[](order.length);
        for (uint256 i; i < order.length; ++i) {
            initial[i] = (i + 11) * SHARE;
            expectedInitial[order[i]] = initial[i];
        }
        vm.prank(GOVERNANCE);
        vault.setInitialAmounts(initial, version);
        vm.prank(ALICE);
        vault.mint(SHARE, initial, SHARE, version);
        for (uint256 i; i < order.length; ++i) expectedReserve[order[i]] = initial[i];
        _assertAccounting();
        assertEq(vault.totalSupply(), SHARE);
    }

    function _assertAccounting() private view {
        IERC20[] memory actualOrder = vault.components();
        uint256[] memory actualReserves = vault.reserves();
        uint256[] memory actualInitial = vault.initialAmounts();
        assertEq(actualOrder.length, order.length);
        assertEq(actualReserves.length, order.length);
        assertEq(actualInitial.length, order.length);
        for (uint256 i; i < order.length; ++i) {
            address token = order[i];
            assertEq(address(actualOrder[i]), token);
            assertEq(actualReserves[i], expectedReserve[token]);
            assertEq(IERC20(token).balanceOf(address(vault)), expectedReserve[token]);
            assertEq(actualInitial[i], expectedInitial[token]);
        }
    }
}
