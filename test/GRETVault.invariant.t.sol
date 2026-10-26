// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";

/// @notice Runs random sequences of every vault operation. Keeps its own ledger of each component
/// movement and records any mismatch with the amounts the vault should have produced.
/// @dev A, B and C stay in the basket at indexes 0 to 2. D starts outside and governance adds it as
/// index 3 and removes it again, so the vault index of every token always equals its ledger index.
contract GRETVaultHandler is CommonBase, StdUtils {
    /// @dev Tokens tracked by the ledger: the three permanent components and D.
    uint256 internal constant TOKENS = 4;
    /// @dev actors[3] never mints: it only receives GRET, like a secondary-market buyer.
    uint256 internal constant MINTERS = 3;
    uint256 internal constant MAX_AMOUNT = 1e24;

    GRETVault public immutable vault;
    MockERC20 public immutable tokenA;
    MockERC20 public immutable tokenB;
    MockFaultyERC20 public immutable tokenC;
    MockERC20 public immutable tokenD;
    address public constant GOVERNANCE = address(0x60F);
    address public constant REBALANCER = address(0x5EB);
    address public constant FEE_RECIPIENT = address(0xFEE);
    address[4] public actors;
    mapping(address account => bool) public everMinted;

    // Independent ledger of token movements, per ledger index.
    uint256[TOKENS] public minted;
    uint256[TOKENS] public donated;
    uint256[TOKENS] public synced;
    uint256[TOKENS] public redeemed;
    uint256[TOKENS] public claimedOut;
    uint256[TOKENS] public rescued;
    uint256[TOKENS] public slashed;
    uint256[TOKENS] public lossRecognized;
    uint256[TOKENS] public swappedIn;
    uint256[TOKENS] public swappedOut;
    uint256[TOKENS] public writtenOffAmount;
    /// @dev Skipped shares that left the reserve because the redemption emptied the supply.
    uint256[TOKENS] public skippedToSurplus;

    // Violations detected while operating; the invariants require all of them to stay false.
    bool public wrongAmount;
    bool public valuePerShareDecreased;
    bool public redeemedWithoutMint;
    bool public governanceChangedWhatIsOwed;
    bool public rescuedBeyondSurplus;
    bool public activationFailed;
    bool public supplyBelowMinimum;
    bool public vaultAcceptedShares;
    bool public swapChangedOtherReserves;
    bool public removedWithReserve;
    bool public rescuedWrittenOff;
    bool public wrongFee;
    bool public mintedWhilePaused;

    /// @notice Successful calls per operation, to check that sequences reach every path.
    mapping(bytes32 operation => uint256) public successes;

    constructor() {
        tokenA = new MockERC20("Mock A", "MA", 18);
        tokenB = new MockERC20("Mock B", "MB", 8);
        tokenC = new MockFaultyERC20("Mock C", "MC", 18);
        tokenD = new MockERC20("Mock D", "MD", 6);

        IERC20[] memory components = new IERC20[](3);
        components[0] = IERC20(address(tokenA));
        components[1] = IERC20(address(tokenB));
        components[2] = IERC20(address(tokenC));
        uint256[] memory initialAmounts = new uint256[](3);
        initialAmounts[0] = 2e18;
        initialAmounts[1] = 1e5;
        initialAmounts[2] = 5e18;
        vault = new GRETVault(components, initialAmounts, GOVERNANCE);

        // Swaps are priced by a guard that accepts all of them: the accounting must hold anyway.
        MockPriceGuard guard = new MockPriceGuard();
        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(guard));
        vm.stopPrank();
        vm.warp(block.timestamp + vault.BASKET_CHANGE_DELAY());
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
        vm.prank(GOVERNANCE);
        vault.setFeeRecipient(FEE_RECIPIENT);

        for (uint256 k; k < actors.length; ++k) {
            actors[k] = address(uint160(0xA11CE0 + k));
        }
        for (uint256 i; i < TOKENS; ++i) {
            for (uint256 k; k < actors.length; ++k) {
                vm.prank(actors[k]);
                _token(i).approve(address(vault), type(uint256).max);
            }
            vm.prank(REBALANCER);
            _token(i).approve(address(vault), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Normal operation
    // ---------------------------------------------------------------------------------------------

    function mint(uint256 actorSeed, uint256 shares) external {
        if (vault.liquidationActive()) return;
        address actor = actors[actorSeed % MINTERS];
        (uint256[TOKENS] memory reservesBefore, uint256 supplyBefore) = _snapshot();
        shares = supplyBefore == 0 ? vault.INITIAL_SHARES() : bound(shares, 1, MAX_AMOUNT);
        uint256 count = vault.componentCount();

        uint256[] memory expected;
        try vault.previewMint(shares) returns (uint256[] memory amounts) {
            expected = amounts;
        } catch {
            return;
        }
        for (uint256 i; i < count; ++i) {
            if (expected[i] > 1e40) return;
            _fund(actor, i, expected[i]);
        }

        // Built before the prank: reading the component count is itself a call to the vault.
        uint256[] memory maxAmountsIn = _filled(type(uint256).max);
        uint256 fee = Math.mulDiv(shares, vault.mintFee(), 10_000);
        uint256 feesBefore = vault.balanceOf(FEE_RECIPIENT);
        bool paused = vault.mintPaused();
        // A prank for the whole statement, since the version is read in the arguments (one more
        // local would not fit in the stack); everything else the vault is asked below is a view.
        vm.startPrank(actor);
        try vault.mint(shares, maxAmountsIn, 0, vault.basketVersion()) returns (uint256 issued, uint256[] memory paid) {
            if (paused) mintedWhilePaused = true;
            successes[fee == 0 ? bytes32("mint") : bytes32("mintWithFee")]++;
            everMinted[actor] = true;
            // Every mock delivers exactly what is requested, so exactly `shares` are issued, of
            // which the fee goes to the recipient.
            if (issued != shares - fee) wrongAmount = true;
            if (vault.balanceOf(FEE_RECIPIENT) - feesBefore != fee) wrongFee = true;
            bool contributed;
            for (uint256 i; i < count; ++i) {
                minted[i] += paid[i];
                // Zero for a component with no reserve (or no initial amount): mint skips it.
                uint256 fair = supplyBefore == 0
                    ? vault.initialAmounts()[i]
                    : Math.mulDiv(shares, reservesBefore[i], supplyBefore, Math.Rounding.Ceil);
                if (paid[i] != fair) wrongAmount = true;
                if (paid[i] != 0) contributed = true;
            }
            if (!contributed) wrongAmount = true;
            _checkValuePerShare(reservesBefore, supplyBefore);
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        if (vault.liquidationActive()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        (uint256[TOKENS] memory reservesBefore, uint256 supplyBefore) = _snapshot();

        uint256[] memory minAmountsOut = _filled(0);
        uint256 fee = Math.mulDiv(shares, vault.redeemFee(), 10_000);
        uint256 feesBefore = vault.balanceOf(FEE_RECIPIENT);
        uint256 version = vault.basketVersion();
        vm.prank(actor);
        try vault.redeem(shares, minAmountsOut, version) returns (uint256[] memory out) {
            successes[fee == 0 ? bytes32("redeem") : bytes32("redeemWithFee")]++;
            if (!everMinted[actor]) redeemedWithoutMint = true;
            // The fee moves to the recipient; only the rest is burned and paid out.
            uint256 burned = shares - fee;
            uint256 remaining = supplyBefore - burned;
            if (remaining != 0 && remaining < vault.MIN_SUPPLY()) supplyBelowMinimum = true;
            if (vault.balanceOf(FEE_RECIPIENT) - feesBefore != fee) wrongFee = true;
            for (uint256 i; i < out.length; ++i) {
                redeemed[i] += out[i];
                if (out[i] != Math.mulDiv(burned, reservesBefore[i], supplyBefore)) wrongAmount = true;
            }
            _checkValuePerShare(reservesBefore, supplyBefore);
        } catch {}
    }

    /// @notice Like `redeem`, leaving out component C, which is never called and whose share stays
    /// in the reserve unless the supply empties.
    function redeemSkipping(uint256 actorSeed, uint256 shares) external {
        if (vault.liquidationActive()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        (uint256[TOKENS] memory reservesBefore, uint256 supplyBefore) = _snapshot();

        uint256[] memory minAmountsOut = _filled(0);
        address[] memory skipped = new address[](1);
        skipped[0] = address(tokenC);
        uint256 fee = Math.mulDiv(shares, vault.redeemFee(), 10_000);
        uint256 version = vault.basketVersion();
        vm.prank(actor);
        try vault.redeemSkipping(shares, minAmountsOut, skipped, version) returns (uint256[] memory out) {
            successes["redeemSkipping"]++;
            if (!everMinted[actor]) redeemedWithoutMint = true;
            uint256 burned = shares - fee;
            uint256 remaining = supplyBefore - burned;
            if (remaining != 0 && remaining < vault.MIN_SUPPLY()) supplyBelowMinimum = true;
            for (uint256 i; i < out.length; ++i) {
                redeemed[i] += out[i];
                uint256 share = Math.mulDiv(burned, reservesBefore[i], supplyBefore);
                if (out[i] != (i == 2 ? 0 : share)) wrongAmount = true;
            }
            if (remaining == 0) skippedToSurplus[2] += Math.mulDiv(burned, reservesBefore[2], supplyBefore);
            if (vault.reserves()[2] != (remaining == 0 ? 0 : reservesBefore[2])) wrongAmount = true;
            _checkValuePerShare(reservesBefore, supplyBefore);
        } catch {}
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        // One destination in five is the vault itself: GRET sent there by mistake must revert.
        if (toSeed % 5 == 4) {
            vm.prank(from);
            try vault.transfer(address(vault), amount) {
                vaultAcceptedShares = true;
            } catch {
                successes["sharesToVaultRejected"]++;
            }
            return;
        }
        vm.prank(from);
        vault.transfer(actors[toSeed % actors.length], amount);
    }

    function donate(uint256 index, uint256 amount) external {
        index %= TOKENS;
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(address(vault), index, amount);
        donated[index] += amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    function sync(uint256 index) external {
        index %= vault.componentCount();
        vm.prank(GOVERNANCE);
        try vault.sync(address(_token(index))) returns (uint256 added) {
            if (added != 0) successes[vault.liquidationActive() ? bytes32("syncInLiquidation") : bytes32("sync")]++;
            synced[index] += added;
        } catch {}
    }

    function rescueComponent(uint256 index, uint256 amount, bool overshoot) external {
        index %= TOKENS;
        uint256[TOKENS] memory owedBefore = _owed();
        address token = address(_token(index));
        // D outside the basket: governance may take its whole balance.
        if (index >= vault.componentCount()) {
            uint256 held = tokenD.balanceOf(address(vault));
            if (held == 0) return;
            amount = bound(amount, 1, held);
            vm.prank(GOVERNANCE);
            vault.rescue(token, GOVERNANCE, amount);
            successes["rescueOutsideBasket"]++;
            rescued[index] += amount;
            _checkOwedUnchanged(owedBefore);
            return;
        }
        uint256 surplus;
        try vault.componentSurplus(index) returns (uint256 value) {
            surplus = value;
        } catch {
            return;
        }

        if (overshoot || surplus == 0) {
            vm.prank(GOVERNANCE);
            try vault.rescue(token, GOVERNANCE, surplus + bound(amount, 1, MAX_AMOUNT)) {
                rescuedBeyondSurplus = true;
            } catch {}
        } else {
            amount = bound(amount, 1, surplus);
            vm.prank(GOVERNANCE);
            try vault.rescue(token, GOVERNANCE, amount) {
                successes[vault.liquidationActive() ? bytes32("rescueInLiquidation") : bytes32("rescue")]++;
                rescued[index] += amount;
                if (vault.writtenOff(token)) rescuedWrittenOff = true;
            } catch {}
        }
        _checkOwedUnchanged(owedBefore);
    }

    /// @notice The issuer removes part of the vault's C, like a negative rebase or a fee. In normal
    /// operation the loss is recognized right away; in liquidation claims absorb it by themselves.
    function slashComponent(uint256 amount) external {
        if (tokenC.fault() == MockFaultyERC20.Fault.RevertOnBalanceOf) return;
        uint256 balance = tokenC.rawBalanceOf(address(vault));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        tokenC.slash(address(vault), amount);
        slashed[2] += amount;
        if (!vault.liquidationActive()) {
            uint256 loss = vault.recognizeLoss(2);
            lossRecognized[2] += loss;
            if (loss != 0) successes["loss"]++;
        } else {
            successes["lossInLiquidation"]++;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Rebalancing
    // ---------------------------------------------------------------------------------------------

    /// @notice The rebalancer delivers one component and takes part of another's reserve.
    function swap(uint256 sellSeed, uint256 buySeed, uint256 sellAmount, uint256 buyAmount) external {
        uint256 count = vault.componentCount();
        uint256 sell = sellSeed % count;
        uint256 buy = (sell + 1 + buySeed % (count - 1)) % count;
        (uint256[TOKENS] memory reservesBefore,) = _snapshot();
        if (reservesBefore[sell] == 0) return;
        sellAmount = bound(sellAmount, 1, reservesBefore[sell]);
        buyAmount = bound(buyAmount, 1, MAX_AMOUNT);
        _fund(REBALANCER, buy, buyAmount);
        uint256 rebalancerBefore = rawBalance(sell, REBALANCER);

        vm.prank(REBALANCER);
        try vault.swap(address(_token(sell)), sellAmount, address(_token(buy)), buyAmount) returns (uint256 received) {
            successes["swap"]++;
            swappedOut[sell] += sellAmount;
            swappedIn[buy] += received;
            if (received != buyAmount || rawBalance(sell, REBALANCER) - rebalancerBefore != sellAmount) {
                wrongAmount = true;
            }
            (uint256[TOKENS] memory reservesAfter,) = _snapshot();
            for (uint256 i; i < count; ++i) {
                uint256 expected = reservesBefore[i];
                if (i == sell) expected -= sellAmount;
                if (i == buy) expected += buyAmount;
                if (reservesAfter[i] != expected) swapChangedOtherReserves = true;
            }
        } catch {
            // Unspent funding stays with the rebalancer, outside the vault's ledger.
        }
    }

    /// @notice Governance proposes D, waits, and any holder adds it as index 3.
    function addComponent(uint256 actorSeed) external {
        if (vault.liquidationActive() || vault.componentCount() == TOKENS) return;
        vm.prank(GOVERNANCE);
        vault.announceComponent(address(tokenD));
        vm.warp(block.timestamp + vault.BASKET_CHANGE_DELAY());
        vm.prank(actors[actorSeed % actors.length]);
        vault.addComponent(address(tokenD));
        successes["addComponent"]++;
    }

    /// @notice Governance removes D, most often after the rebalancer sold all of it for A.
    function removeComponent(bool sellFirst) external {
        if (vault.liquidationActive() || vault.componentCount() != TOKENS) return;
        uint256 reserve = vault.reserves()[3];
        if (reserve != 0 && sellFirst) {
            _fund(REBALANCER, 0, 1);
            vm.prank(REBALANCER);
            vault.swap(address(tokenD), reserve, address(tokenA), 1);
            swappedOut[3] += reserve;
            swappedIn[0] += 1;
            reserve = 0;
        }
        vm.prank(GOVERNANCE);
        try vault.removeComponent(address(tokenD)) {
            successes["removeComponent"]++;
            if (reserve != 0) removedWithReserve = true;
        } catch {
            if (reserve == 0) wrongAmount = true;
        }
    }

    /// @notice Governance proposes writing off C while one of its faults stops the vault from
    /// reading or sending it, and any holder executes it after the wait. Rare, so that C usually
    /// stays in the basket.
    function writeOff(uint256 seed) external {
        if (vault.liquidationActive() || tokenC.fault() == MockFaultyERC20.Fault.None || seed % 4 != 0) return;
        uint256 reserve = vault.reserves()[2];
        if (reserve == 0) return;
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(address(tokenC));
        vm.warp(block.timestamp + vault.BASKET_CHANGE_DELAY());
        vm.prank(actors[seed % actors.length]);
        vault.writeOffComponent(address(tokenC));
        successes["writeOff"]++;
        writtenOffAmount[2] += reserve;
    }

    /// @notice Governance sets both fees within the cap; a raise waits and any holder applies it.
    function setFees(uint256 mintFee, uint256 redeemFee) external {
        uint256 maxFee = vault.MAX_FEE();
        mintFee = bound(mintFee, 0, maxFee);
        redeemFee = bound(redeemFee, 0, maxFee);
        vm.prank(GOVERNANCE);
        vault.proposeFees(mintFee, redeemFee);
        if (vault.pendingFeesReadyAt() != 0) {
            vm.warp(block.timestamp + vault.FEE_INCREASE_DELAY());
            vm.prank(actors[mintFee % actors.length]);
            vault.applyFees();
        }
        if (vault.mintFee() != mintFee || vault.redeemFee() != redeemFee) wrongFee = true;
        if (mintFee > maxFee || redeemFee > maxFee) wrongFee = true;
    }

    /// @notice Governance pauses minting now and then, and resumes it.
    function setMintPaused(uint256 seed) external {
        vm.prank(GOVERNANCE);
        vault.setMintPaused(seed % 4 == 0);
    }

    function activateLiquidation(uint256 seed) external {
        // Rare, so that sequences explore normal operation before liquidation.
        if (vault.liquidationActive() || seed % 8 != 0) return;
        vm.prank(GOVERNANCE);
        try vault.activateLiquidation() {
            successes["activate"]++;
        } catch {
            activationFailed = true;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------------------------------

    function convert(uint256 actorSeed, uint256 amount) external {
        if (!vault.liquidationActive()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        vm.prank(actor);
        vault.convertToClaims(bound(amount, 1, balance));
    }

    function claim(uint256 actorSeed, uint256 index) external {
        if (!vault.liquidationActive()) return;
        address actor = actors[actorSeed % actors.length];
        index %= vault.componentCount();
        uint256 pending = vault.claimable(actor, index);
        uint256 rights = entitlement(actor, index) - vault.claimed(actor, index);
        if (vault.pendingRights(actor, index) != rights) wrongAmount = true;
        // Paid in full while the vault covers every pending right, otherwise pro rata.
        uint256 owed = vault.reserves()[index] - vault.rightsClaimed()[index];
        if (tokenC.fault() != MockFaultyERC20.Fault.RevertOnBalanceOf || index != 2) {
            uint256 held = rawBalance(index, address(vault));
            uint256 expected = held >= owed ? rights : Math.mulDiv(rights, held, owed);
            if (pending != expected) wrongAmount = true;
        }
        uint256 balanceBefore = rawBalance(index, actor);

        vm.prank(actor);
        try vault.claim(index, actor, 0) returns (uint256 amount) {
            successes["claim"]++;
            claimedOut[index] += amount;
            if (amount != pending || rawBalance(index, actor) - balanceBefore != amount) wrongAmount = true;
        } catch {
            if (pending != 0) successes["failedClaimKeptRight"]++;
            // A failed claim leaves the right exactly where it was.
            if (vault.claimable(actor, index) != pending) wrongAmount = true;
        }
    }

    /// @notice Switches component C between faults that never change transferred amounts, so
    /// the ledger stays exact.
    function setComponentFault(uint256 mode) external {
        MockFaultyERC20.Fault[4] memory modes = [
            MockFaultyERC20.Fault.None,
            MockFaultyERC20.Fault.RevertOnTransfer,
            MockFaultyERC20.Fault.ReturnFalseOnTransfer,
            MockFaultyERC20.Fault.RevertOnBalanceOf
        ];
        tokenC.setFault(modes[mode % modes.length]);
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function rawBalance(uint256 index, address account) public view returns (uint256) {
        return index == 2 ? tokenC.rawBalanceOf(account) : _token(index).balanceOf(account);
    }

    /// @notice What the ledger says the vault's recognized reserve of a token should be.
    function ledgerReserve(uint256 index) public view returns (uint256) {
        return minted[index] + synced[index] + swappedIn[index] - redeemed[index] - lossRecognized[index]
            - swappedOut[index] - writtenOffAmount[index] - skippedToSurplus[index];
    }

    function entitlement(address account, uint256 index) public view returns (uint256) {
        uint256 shares = vault.claimShares(account);
        if (shares == 0) return 0;
        return Math.mulDiv(shares, vault.reserves()[index], vault.liquidationSupply());
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _token(uint256 index) internal view returns (IERC20) {
        if (index == 0) return IERC20(address(tokenA));
        if (index == 1) return IERC20(address(tokenB));
        if (index == 2) return IERC20(address(tokenC));
        return IERC20(address(tokenD));
    }

    function _fund(address account, uint256 index, uint256 amount) internal {
        if (index == 0) tokenA.mint(account, amount);
        else if (index == 1) tokenB.mint(account, amount);
        else if (index == 2) tokenC.mint(account, amount);
        else tokenD.mint(account, amount);
    }

    function _filled(uint256 value) internal view returns (uint256[] memory values) {
        values = new uint256[](vault.componentCount());
        for (uint256 i; i < values.length; ++i) {
            values[i] = value;
        }
    }

    /// @dev Reserves by ledger index; zero for D while it is outside the basket.
    function _snapshot() internal view returns (uint256[TOKENS] memory reserves, uint256 supply) {
        uint256[] memory current = vault.reserves();
        for (uint256 i; i < current.length; ++i) {
            reserves[i] = current[i];
        }
        supply = vault.totalSupply();
    }

    function _owed() internal view returns (uint256[TOKENS] memory owed) {
        uint256[] memory reserves = vault.reserves();
        uint256[] memory claimedTotals = vault.rightsClaimed();
        for (uint256 i; i < reserves.length; ++i) {
            owed[i] = reserves[i] - claimedTotals[i];
        }
    }

    function _checkOwedUnchanged(uint256[TOKENS] memory owedBefore) internal {
        uint256[TOKENS] memory owedAfter = _owed();
        for (uint256 i; i < TOKENS; ++i) {
            if (owedAfter[i] != owedBefore[i]) governanceChangedWhatIsOwed = true;
        }
    }

    /// @dev Rounding favors holders: the amount behind each GRET never goes down.
    function _checkValuePerShare(uint256[TOKENS] memory reservesBefore, uint256 supplyBefore) internal {
        (uint256[TOKENS] memory reservesAfter, uint256 supplyAfter) = _snapshot();
        if (supplyBefore == 0 || supplyAfter == 0) return;
        for (uint256 i; i < TOKENS; ++i) {
            if (reservesAfter[i] * supplyBefore < reservesBefore[i] * supplyAfter) valuePerShareDecreased = true;
        }
    }
}

contract GRETVaultInvariantTest is Test {
    GRETVaultHandler internal handler;
    GRETVault internal vault;

    function setUp() public {
        handler = new GRETVaultHandler();
        vault = handler.vault();

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = GRETVaultHandler.mint.selector;
        selectors[1] = GRETVaultHandler.redeem.selector;
        selectors[2] = GRETVaultHandler.transferShares.selector;
        selectors[3] = GRETVaultHandler.donate.selector;
        selectors[4] = GRETVaultHandler.sync.selector;
        selectors[5] = GRETVaultHandler.rescueComponent.selector;
        selectors[6] = GRETVaultHandler.activateLiquidation.selector;
        selectors[7] = GRETVaultHandler.convert.selector;
        selectors[8] = GRETVaultHandler.claim.selector;
        selectors[9] = GRETVaultHandler.setComponentFault.selector;
        selectors[10] = GRETVaultHandler.slashComponent.selector;
        selectors[11] = GRETVaultHandler.swap.selector;
        selectors[12] = GRETVaultHandler.addComponent.selector;
        selectors[13] = GRETVaultHandler.removeComponent.selector;
        selectors[14] = GRETVaultHandler.writeOff.selector;
        selectors[15] = GRETVaultHandler.setFees.selector;
        selectors[16] = GRETVaultHandler.redeemSkipping.selector;
        selectors[17] = GRETVaultHandler.setMintPaused.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Every unit that entered or left the vault is accounted for, D included while outside.
    function invariant_componentBalancesMatchLedger() public view {
        for (uint256 i; i < 4; ++i) {
            uint256 expected = handler.minted(i) + handler.donated(i) + handler.swappedIn(i) - handler.redeemed(i)
                - handler.claimedOut(i) - handler.rescued(i) - handler.slashed(i) - handler.swappedOut(i);
            assertEq(handler.rawBalance(i, address(vault)), expected, "component balance");
        }
    }

    /// Reserves only change through mint, sync, swaps, normal redemption, recognized losses and
    /// write-offs, and a token leaves the basket only with no reserve.
    function invariant_reservesMatchLedger() public view {
        uint256[] memory reserves = vault.reserves();
        uint256[] memory claimedTotals = vault.totalClaimed();
        for (uint256 i; i < reserves.length; ++i) {
            assertEq(reserves[i], handler.ledgerReserve(i), "reserve");
            assertEq(claimedTotals[i], handler.claimedOut(i), "total claimed");
        }
        if (reserves.length == 3) assertEq(handler.ledgerReserve(3), 0, "reserve outside the basket");
    }

    /// The vault always holds at least what it owes: its reserves in normal operation, and
    /// everything that can still be claimed during liquidation.
    function invariant_vaultCoversWhatItOwes() public view {
        uint256[] memory reserves = vault.reserves();
        uint256[] memory rights = vault.rightsClaimed();
        uint256[] memory claimedTotals = vault.totalClaimed();
        for (uint256 i; i < reserves.length; ++i) {
            uint256 held = handler.rawBalance(i, address(vault));
            assertLe(rights[i], reserves[i], "rights above reserve");
            assertLe(claimedTotals[i], rights[i], "paid above rights");
            if (!vault.liquidationActive()) {
                assertGe(held, reserves[i], "insolvent");
                continue;
            }
            if (i == 2 && handler.tokenC().fault() == MockFaultyERC20.Fault.RevertOnBalanceOf) continue;
            uint256 claimableTotal;
            for (uint256 k; k < handler.actorCount(); ++k) {
                claimableTotal += vault.claimable(handler.actors(k), i);
            }
            assertLe(claimableTotal, held, "claimable above balance");
        }
    }

    /// In normal operation reserves are empty when there is no GRET. Otherwise A, B and C stay
    /// positive unless a loss wiped them, the rebalancer sold them or C was written off, swaps never
    /// empty the whole basket, and the supply is either zero or at least MIN_SUPPLY.
    function invariant_supplyAndReservesMoveTogether() public view {
        if (vault.liquidationActive()) return;
        uint256[] memory reserves = vault.reserves();
        uint256 supply = vault.totalSupply();
        assertTrue(supply == 0 || supply >= vault.MIN_SUPPLY(), "supply below minimum");
        uint256 total;
        for (uint256 i; i < reserves.length; ++i) {
            total += reserves[i];
            if (supply == 0) assertEq(reserves[i], 0, "reserve without supply");
            else if (
                i < 3 && handler.lossRecognized(i) == 0 && handler.swappedOut(i) == 0
                    && handler.writtenOffAmount(i) == 0
            ) {
                assertGt(reserves[i], 0, "supply without reserve");
            }
        }
        if (supply != 0 && handler.lossRecognized(2) == 0 && handler.writtenOffAmount(2) == 0) {
            assertGt(total, 0, "supply without basket");
        }
    }

    /// During liquidation, converted and unconverted GRET add up to the snapshot, and nobody has
    /// been paid more than their share.
    function invariant_liquidationRightsAddUp() public view {
        if (!vault.liquidationActive()) return;
        uint256 converted;
        for (uint256 k; k < handler.actorCount(); ++k) {
            address actor = handler.actors(k);
            converted += vault.claimShares(actor);
            for (uint256 i; i < vault.componentCount(); ++i) {
                assertLe(vault.claimed(actor, i), handler.entitlement(actor, i), "claimed above entitlement");
            }
        }
        assertEq(converted + vault.totalSupply(), vault.liquidationSupply(), "liquidation shares");
    }

    function invariant_noViolationsDuringOperations() public view {
        assertFalse(handler.wrongAmount(), "wrong amount");
        assertFalse(handler.valuePerShareDecreased(), "value per share decreased");
        assertFalse(handler.redeemedWithoutMint(), "redeemed without a previous mint");
        assertFalse(handler.governanceChangedWhatIsOwed(), "governance changed what is owed");
        assertFalse(handler.rescuedBeyondSurplus(), "rescued beyond surplus");
        assertFalse(handler.activationFailed(), "activation failed");
        assertFalse(handler.supplyBelowMinimum(), "supply below minimum");
        assertFalse(handler.vaultAcceptedShares(), "vault accepted GRET");
        assertFalse(handler.swapChangedOtherReserves(), "swap changed the wrong reserves");
        assertFalse(handler.removedWithReserve(), "removed a component with reserve");
        assertFalse(handler.rescuedWrittenOff(), "rescued a written-off token");
        assertFalse(handler.wrongFee(), "wrong fee");
        assertFalse(handler.mintedWhilePaused(), "minted while paused");
        assertLe(vault.mintFee(), vault.MAX_FEE(), "mint fee above the cap");
        assertLe(vault.redeemFee(), vault.MAX_FEE(), "redeem fee above the cap");
        assertEq(vault.balanceOf(address(vault)), 0, "vault holds GRET");
    }
}
