// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GRETVault} from "../contracts/GRETVault.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";

/// @notice Stateful live-balance operations with an independent physical-supply ledger.
/// Tokens use exact transfers or explicit failures; short deliveries have separate fuzz tests.
contract GRETVaultHandler is Test {
    GRETVault public vault;
    MockFaultyERC20[4] public tokens;
    address[5] public actors;
    uint256[4] public issued;
    uint256[4] public lost;
    uint256[4] public liquidationInflow;
    mapping(address => mapping(uint256 => uint256)) public receivedInClaims;
    mapping(address => mapping(uint256 => uint256)) public successfulClaims;

    struct Flow {
        uint256 supply;
        uint256 actorShares;
        uint256 recipientShares;
        uint256[4] backing;
        uint256[4] actorTokens;
    }
    mapping(address => bool) public everMinted;
    mapping(bytes32 => uint256) public successes;
    bool public violation;

    constructor() {
        IERC20[] memory basket = new IERC20[](3);
        uint256[] memory initial = new uint256[](3);
        for (uint256 i; i < 4; ++i) {
            tokens[i] = new MockFaultyERC20("Invariant", "INV", i == 1 ? 8 : 18);
            if (i < 3) { basket[i] = tokens[i]; initial[i] = i == 1 ? 100_000 : 100e18; }
        }
        for (uint256 k; k < 5; ++k) actors[k] = address(uint160(0xA000 + k));
        vault = new GRETVault(basket, initial, address(this));
        for (uint256 i; i < 4; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
            for (uint256 k; k < 5; ++k) {
                _fund(i, actors[k], 1e36);
                vm.prank(actors[k]);
                tokens[i].approve(address(vault), type(uint256).max);
            }
        }
        vm.prank(actors[0]);
        vault.mint(1e18, initial, 1e18, 0);
        everMinted[actors[0]] = true;
        vault.setFeeRecipient(actors[4]);
        vault.proposeRebalancer(address(this));
        vault.proposePriceGuard(address(new MockPriceGuard()));
        vm.warp(block.timestamp + 7 days);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
    }

    function mint(uint256 who, uint256 seed) external {
        if (vault.liquidationActive()) return;
        address actor = actors[who % 3]; // Two secondary holders never qualify by minting.
        uint256 shares = vault.totalSupply() == 0 ? 1e18 : bound(seed, 1, 10e18);
        uint256[] memory limits = new uint256[](vault.componentCount());
        for (uint256 i; i < limits.length; ++i) limits[i] = type(uint256).max;
        uint256 version = vault.basketVersion();
        Flow memory before_ = _flow(actor);
        uint256[] memory expected = vault.initialAmounts();
        uint256 fee = (shares * vault.mintFee() + 9_999) / 10_000; // rounded up
        for (uint256 i; i < expected.length; ++i) {
            if (vault.excluded(address(tokens[i]))) expected[i] = 0;
            else if (before_.supply != 0) {
                uint256 product = shares * before_.backing[i];
                expected[i] = product / before_.supply + (product % before_.supply == 0 ? 0 : 1);
            }
        }
        vm.prank(actor);
        try vault.mint(shares, limits, 1, version) returns (uint256 minted, uint256[] memory received) {
            if (minted + fee != shares || vault.totalSupply() != before_.supply + shares ||
                vault.balanceOf(actor) != before_.actorShares + shares - fee ||
                vault.balanceOf(actors[4]) != before_.recipientShares + fee) violation = true;
            for (uint256 i; i < expected.length; ++i) {
                if (received[i] != expected[i] ||
                    tokens[i].rawBalanceOf(address(vault)) != before_.backing[i] + expected[i] ||
                    tokens[i].rawBalanceOf(actor) + expected[i] != before_.actorTokens[i]) violation = true;
            }
            everMinted[actor] = true;
            successes["mint"]++;
            if (vault.mintPaused()) violation = true;
            _checkNoDilution(before_.backing, before_.supply);
        } catch {}
    }

    function redeem(uint256 who, uint256 seed, bool skip) external {
        if (vault.liquidationActive()) return;
        address actor = actors[who % 5];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(seed, 1, balance);
        address[] memory skipped = new address[](skip ? 1 : 0);
        if (skip) skipped[0] = address(tokens[2]);
        uint256[] memory limits = new uint256[](vault.componentCount());
        uint256 version = vault.basketVersion();
        Flow memory before_ = _flow(actor);
        // Redeeming the whole supply pays no fee.
        uint256 fee = shares == before_.supply ? 0 : (shares * vault.redeemFee() + 9_999) / 10_000;
        uint256 burned = shares - fee;
        uint256[] memory expected = new uint256[](limits.length);
        for (uint256 i; i < expected.length; ++i) {
            if (!vault.excluded(address(tokens[i])) && !(skip && i == 2)) {
                expected[i] = burned * before_.backing[i] / before_.supply;
            }
        }
        vm.prank(actor);
        try vault.redeemSkipping(shares, limits, skipped, version) returns (uint256[] memory paid) {
            if (vault.totalSupply() + burned != before_.supply ||
                vault.balanceOf(actor) + shares != before_.actorShares + (actor == actors[4] ? fee : 0) ||
                vault.balanceOf(actors[4]) + (actor == actors[4] ? shares : 0) != before_.recipientShares + fee) {
                violation = true;
            }
            for (uint256 i; i < expected.length; ++i) {
                if (paid[i] != expected[i] ||
                    tokens[i].rawBalanceOf(address(vault)) + expected[i] != before_.backing[i] ||
                    tokens[i].rawBalanceOf(actor) != before_.actorTokens[i] + expected[i]) violation = true;
            }
            successes[skip ? bytes32("skip") : bytes32("redeem")]++;
            if (!everMinted[actor]) violation = true;
            _checkNoDilution(before_.backing, before_.supply);
        } catch {}
    }

    function transferShares(uint256 from, uint256 to, uint256 seed) external {
        address sender = actors[from % 5];
        uint256 amount = seed % (vault.balanceOf(sender) + 1);
        vm.prank(sender);
        vault.transfer(actors[to % 5], amount);
    }

    function donate(uint256 index, uint256 amount) external {
        index %= 4;
        amount = bound(amount, 1, 1e22);
        _fund(index, address(vault), amount);
        if (vault.liquidationActive()) liquidationInflow[index] += amount;
        successes["donate"]++;
    }

    function slash(uint256 index, uint256 seed) external {
        index %= 4;
        uint256 held = tokens[index].rawBalanceOf(address(vault));
        uint256 amount = seed % (held + 1);
        tokens[index].slash(address(vault), amount);
        lost[index] += amount;
        successes["slash"]++;
    }

    function fault(uint256 seed) external {
        MockFaultyERC20.Fault[4] memory modes = [MockFaultyERC20.Fault.None,
            MockFaultyERC20.Fault.RevertOnTransfer, MockFaultyERC20.Fault.ReturnFalseOnTransfer,
            MockFaultyERC20.Fault.RevertOnBalanceOf];
        tokens[2].setFault(modes[seed % 4]);
    }

    function swap(uint256 sell, uint256 buy, uint256 seed) external {
        if (vault.liquidationActive()) return;
        sell %= vault.componentCount(); buy %= vault.componentCount();
        if (sell == buy) return;
        uint256 held = tokens[sell].rawBalanceOf(address(vault));
        if (held == 0) return;
        uint256 amount = bound(seed, 1, held);
        _fund(buy, address(this), amount);
        try vault.swap(address(tokens[sell]), amount, address(tokens[buy]), amount) {
            successes["swap"]++;
        } catch {}
    }

    function component(uint256 index, uint256 action) external {
        if (vault.liquidationActive()) return;
        index %= vault.componentCount();
        address token = address(tokens[index]);
        if (action % 3 == 0) {
            try vault.activateComponent(token) { successes["activateComponent"]++; } catch {}
        } else if (action % 3 == 1) {
            try vault.deactivateEmptyComponent(token) { successes["deactivate"]++; } catch {}
        } else {
            vault.proposeWriteOff(token);
            vm.warp(block.timestamp + 7 days);
            try vault.writeOffComponent(token) { successes["writeOff"]++; } catch {}
        }
    }

    function changeBasket(bool add) external {
        if (vault.liquidationActive()) return;
        if (add && vault.componentCount() == 3) {
            vault.announceComponent(address(tokens[3]));
            vm.warp(block.timestamp + 7 days);
            vault.addComponent(address(tokens[3]));
            successes["add"]++;
        } else if (!add && vault.componentCount() == 4) {
            uint256 balanceBefore = tokens[3].rawBalanceOf(address(vault));
            bool wasWrittenOff = vault.writtenOff(address(tokens[3]));
            try vault.removeComponent(address(tokens[3])) {
                successes["remove"]++;
                // Check eligibility independently of the vault's internal helper.
                uint256 allowed = tokens[3].decimals() >= 18 ? 10 : 0;
                if (balanceBefore > allowed || wasWrittenOff) violation = true;
            } catch {}
        }
    }

    function rescue(uint256 index, uint256 seed) external {
        index %= 4;
        uint256 amount = bound(seed, 1, 1e22);
        bool forbidden = vault.writtenOff(address(tokens[index])) ||
            (index < vault.componentCount() && (vault.liquidationActive() || vault.totalSupply() > 0));
        try vault.rescue(address(tokens[index]), address(this), amount) {
            successes["rescue"]++;
            if (forbidden) violation = true;
        } catch {}
    }

    function fees(uint256 mintFee, uint256 redeemFee) external {
        vault.proposeFees(mintFee % 501, redeemFee % 501);
        if (vault.pendingFeesReadyAt() != 0) {
            vm.warp(block.timestamp + 7 days);
            vault.applyFees();
        }
    }

    function pause(bool value) external { vault.setMintPaused(value); }

    function liquidate(uint256 seed) external {
        // Keep most sequences in normal operation long enough to exercise mutations.
        if (seed % 8 != 0 || vault.liquidationActive()) return;
        uint256[4] memory before_ = _balances();
        try vault.activateLiquidation() {
            liquidationInflow = before_;
            successes["liquidate"]++;
        } catch {
            if (vault.totalSupply() != 0) violation = true;
        }
    }

    function convert(uint256 who, uint256 seed) external {
        address actor = actors[who % 5];
        uint256 amount = seed % (vault.balanceOf(actor) + 1);
        vm.prank(actor);
        try vault.convertToClaims(amount) { successes["convert"]++; } catch {}
    }

    function claim(uint256 who, uint256 index) external {
        address actor = actors[who % 5]; index %= vault.componentCount();
        uint256 before_ = tokens[index].rawBalanceOf(actor);
        vm.prank(actor);
        try vault.claim(index, actor, 0) returns (uint256 paid) {
            uint256 delivered = tokens[index].rawBalanceOf(actor) - before_;
            receivedInClaims[actor][index] += delivered;
            successfulClaims[actor][index]++;
            if (paid != delivered) violation = true;
            successes["claim"]++;
        } catch {}
    }

    function _flow(address actor) private view returns (Flow memory result) {
        result.supply = vault.totalSupply();
        result.actorShares = vault.balanceOf(actor);
        result.recipientShares = vault.balanceOf(actors[4]);
        result.backing = _balances();
        for (uint256 i; i < 4; ++i) result.actorTokens[i] = tokens[i].rawBalanceOf(actor);
    }

    function _balances() private view returns (uint256[4] memory result) {
        for (uint256 i; i < 4; ++i) result[i] = tokens[i].rawBalanceOf(address(vault));
    }

    /// @dev Economic property, independent of the vault's rounding implementation: an
    /// ordinary mint or redemption must never lower active backing per remaining share.
    function _checkNoDilution(uint256[4] memory before_, uint256 supplyBefore) private {
        uint256 supplyAfter = vault.totalSupply();
        if (supplyBefore == 0 || supplyAfter == 0) return;
        for (uint256 i; i < vault.componentCount(); ++i) {
            if (vault.excluded(address(tokens[i]))) continue;
            if (tokens[i].rawBalanceOf(address(vault)) * supplyBefore < before_[i] * supplyAfter) {
                violation = true;
            }
        }
    }

    function _fund(uint256 i, address to, uint256 amount) private {
        tokens[i].mint(to, amount);
        issued[i] += amount;
    }
}

contract GRETVaultInvariantTest is Test {
    GRETVaultHandler internal handler;
    GRETVault internal vault;

    function setUp() public virtual {
        handler = new GRETVaultHandler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.mint.selector; selectors[1] = handler.redeem.selector;
        selectors[2] = handler.transferShares.selector; selectors[3] = handler.donate.selector;
        selectors[4] = handler.slash.selector; selectors[5] = handler.fault.selector;
        selectors[6] = handler.swap.selector; selectors[7] = handler.component.selector;
        selectors[8] = handler.changeBasket.selector; selectors[9] = handler.rescue.selector;
        selectors[10] = handler.fees.selector; selectors[11] = handler.pause.selector;
        selectors[12] = handler.liquidate.selector; selectors[13] = handler.convert.selector;
        selectors[14] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_physicalAssetsAreConserved() public view {
        for (uint256 i; i < 4; ++i) {
            MockFaultyERC20 token = handler.tokens(i);
            uint256 total = token.rawBalanceOf(address(vault)) + token.rawBalanceOf(address(handler));
            for (uint256 k; k < 5; ++k) total += token.rawBalanceOf(handler.actors(k));
            assertEq(total + handler.lost(i), handler.issued(i));
        }
    }

    function invariant_claimsNeverExceedAssets() public view {
        if (!vault.liquidationActive()) return;
        uint256 converted;
        for (uint256 k; k < 5; ++k) converted += vault.convertedShares(handler.actors(k));
        assertEq(converted + vault.totalSupply(), vault.liquidationSupply());
        for (uint256 i; i < vault.componentCount(); ++i) {
            if (i == 2 && handler.tokens(i).fault() == MockFaultyERC20.Fault.RevertOnBalanceOf) continue;
            uint256 payableTotal;
            for (uint256 k; k < 5; ++k) payableTotal += vault.claimable(handler.actors(k), i);
            assertLe(payableTotal, handler.tokens(i).rawBalanceOf(address(vault)));
        }
    }

    function invariant_eachHolderStaysWithinItsLiquidationAllocation() public view {
        if (!vault.liquidationActive()) return;
        uint256 supply = vault.liquidationSupply();
        uint256[] memory basis = vault.liquidationBasis();
        for (uint256 i; i < vault.componentCount(); ++i) {
            uint256 receivedTotal;
            for (uint256 k; k < 5; ++k) {
                address actor = handler.actors(k);
                uint256 shares = vault.convertedShares(actor);
                // Nominal consumed rights cannot exceed this holder's established entitlement.
                assertLe(vault.consumedRights(actor, i), shares * basis[i] / supply);
                // Independent cash ceiling: activation balance plus subsequent external inflows.
                // At most one base unit per successful claim accounts for sequential rounding.
                uint256 received = handler.receivedInClaims(actor, i);
                assertLe(received, shares * handler.liquidationInflow(i) / supply +
                    handler.successfulClaims(actor, i));
                receivedTotal += received;
            }
            assertEq(receivedTotal, vault.totalPaid()[i]);
        }
    }

    function invariant_claimLedgersMatchIndividualRights() public view {
        uint256[] memory consumed = vault.totalConsumedRights();
        uint256[] memory paid = vault.totalPaid();
        uint256[] memory basis = vault.liquidationBasis();
        for (uint256 i; i < vault.componentCount(); ++i) {
            uint256 individual;
            for (uint256 k; k < 5; ++k) individual += vault.consumedRights(handler.actors(k), i);
            assertEq(individual, consumed[i]);
            assertLe(paid[i], consumed[i]);
            assertLe(consumed[i], basis[i]);
            if (!vault.liquidationActive()) assertEq(basis[i], 0);
        }
        assertLe(vault.mintFee(), vault.MAX_FEE());
        assertLe(vault.redeemFee(), vault.MAX_FEE());
    }

    function invariant_permissionsAndShareSupplyHold() public view {
        assertFalse(handler.violation());
        uint256 shares;
        for (uint256 k; k < 5; ++k) {
            address actor = handler.actors(k);
            shares += vault.balanceOf(actor);
            assertEq(vault.hasMinted(actor), handler.everMinted(actor));
        }
        assertEq(shares, vault.totalSupply());
        assertEq(vault.balanceOf(address(vault)), 0);
        if (!vault.liquidationActive()) assertTrue(shares == 0 || shares >= vault.MIN_SUPPLY());
    }
}

/// @notice Start in liquidation with two converted holders, an excluded component and
/// a consumed claim, so every generated sequence exercises recovery and pending rights.
contract GRETVaultLiquidationInvariantTest is GRETVaultInvariantTest {
    function setUp() public override {
        super.setUp();
        handler.mint(1, 1e18);
        handler.component(2, 2);
        handler.liquidate(0);
        handler.convert(0, 1e18);
        handler.convert(1, 1e18);
        handler.claim(0, 0);
    }
}

/// @notice Start with income, a loss, an exclusion and a new inactive component; later
/// operations must conserve physical assets.
contract GRETVaultChangedBalancesInvariantTest is GRETVaultInvariantTest {
    function setUp() public override {
        super.setUp();
        handler.donate(0, 50e18);
        handler.slash(1, 40_000);
        handler.component(2, 2);
        handler.changeBasket(true);
        handler.donate(3, 1e18);
    }
}
