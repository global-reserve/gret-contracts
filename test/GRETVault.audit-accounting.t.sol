// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

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

/// @notice Economic properties across receipt rounding, unrecognized losses, donations and fees.
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
        uint256 effectiveReserve = Math.min(initial, rounding.balanceOf(address(vault)));
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
