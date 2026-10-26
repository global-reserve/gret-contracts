// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GRETVault} from "../../contracts/GRETVault.sol";
import {ChainlinkPriceGuard, IChainlinkFeed} from "../../contracts/ChainlinkPriceGuard.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../../contracts/mocks/MockFaultyERC20.sol";

/// @notice Shared setup of the Solidity case tests: a basket of a healthy component (2 per GRET)
/// and a faulty one (5 per GRET). Alice, Bob and the rebalancer hold both and approved the vault,
/// and Alice minted 1 GRET.
abstract contract GRETVaultCase is Test {
    address internal constant GOVERNANCE = address(0x60F);
    address internal constant REBALANCER = address(0x5EB);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint256 internal constant SHARE = 1e18;

    GRETVault internal vault;
    MockERC20 internal healthy;
    MockFaultyERC20 internal faulty;

    function setUp() public {
        healthy = new MockERC20("Healthy", "H", 18);
        faulty = new MockFaultyERC20("Faulty", "F", 18);
        IERC20[] memory basket = new IERC20[](2);
        basket[0] = healthy;
        basket[1] = faulty;
        vault = new GRETVault(basket, _pair(2e18, 5e18), GOVERNANCE);
        for (uint256 i; i < 3; ++i) {
            address user = i == 0 ? ALICE : i == 1 ? BOB : REBALANCER;
            healthy.mint(user, 1e24);
            faulty.mint(user, 1e24);
            vm.startPrank(user);
            healthy.approve(address(vault), type(uint256).max);
            faulty.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(ALICE);
        vault.mint(SHARE, _pair(2e18, 5e18), SHARE, 0);
    }

    /// @dev Appoints the rebalancer and `guard` through the vault's seven-day wait.
    function _appoint(GRETVault target, address guard) internal {
        vm.startPrank(GOVERNANCE);
        target.proposeRebalancer(REBALANCER);
        target.proposePriceGuard(guard);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(REBALANCER);
        target.acceptRebalancer();
        target.applyPriceGuard();
    }

    /// @dev Appoints the rebalancer and a `ChainlinkPriceGuard` that prices H at $100 and F at $40,
    /// so each GRET is worth $400.
    function _chainlinkGuard() internal returns (ChainlinkPriceGuard guard) {
        MockAggregator healthyFeed = new MockAggregator(8, 100e8);
        MockAggregator faultyFeed = new MockAggregator(8, 40e8);
        address[] memory tokens = new address[](2);
        tokens[0] = address(healthy);
        tokens[1] = address(faulty);
        IChainlinkFeed[] memory feeds = new IChainlinkFeed[](2);
        feeds[0] = IChainlinkFeed(address(healthyFeed));
        feeds[1] = IChainlinkFeed(address(faultyFeed));
        guard = new ChainlinkPriceGuard(address(vault), tokens, feeds, _pair(1 days, 1 days));
        _appoint(vault, address(guard));
        // Fresh prices after the wait.
        healthyFeed.setAnswer(100e8);
        faultyFeed.setAnswer(40e8);
    }

    /// @dev A vault of `token` alone, in which Alice and Bob minted 1 GRET each.
    function _single(CaseToken token, uint256 initial) internal returns (GRETVault single) {
        IERC20[] memory basket = new IERC20[](1);
        basket[0] = token;
        single = new GRETVault(basket, _one(initial), GOVERNANCE);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : BOB;
            token.mint(user, initial);
            vm.startPrank(user);
            token.approve(address(single), initial);
            single.mint(SHARE, _one(initial), SHARE, 0);
            vm.stopPrank();
        }
    }

    function _one(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory values) {
        values = new uint256[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
    }
}

/// @dev Hypothetical token behaviors, not claims about the current components.
abstract contract CaseToken is ERC20 {
    bool internal enabled;

    constructor(string memory name_) ERC20(name_, "CT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Turns on the token's adverse behavior.
    function enable() external {
        enabled = true;
    }
}

/// @dev Once enabled, every transfer also burns 1% of the amount from the sender.
contract SenderSurchargeToken is CaseToken {
    constructor() CaseToken("Sender surcharge") {}

    function _update(address from, address to, uint256 amount) internal override {
        if (enabled && from != address(0) && to != address(0)) {
            super._update(from, address(0), amount / 100);
        }
        super._update(from, to, amount);
    }
}

/// @dev Once enabled, `transfer` returns true without moving anything.
contract NoOpTransferToken is CaseToken {
    constructor() CaseToken("No-op transfer") {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        return enabled ? true : super.transfer(to, amount);
    }
}

/// @dev Once enabled, `balanceOf` and transfers spin until they run out of gas.
contract GasBurnerToken is CaseToken {
    constructor() CaseToken("Gas burner") {}

    function balanceOf(address account) public view override returns (uint256) {
        if (enabled) _spin();
        return super.balanceOf(account);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (enabled && from != address(0) && to != address(0)) _spin();
        super._update(from, to, amount);
    }

    function _spin() private pure {
        uint256 i;
        while (true) {
            ++i;
        }
    }
}
