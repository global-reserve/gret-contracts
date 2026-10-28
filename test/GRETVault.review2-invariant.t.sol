// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFaultyERC20} from "../contracts/mocks/MockFaultyERC20.sol";
import {MockPriceGuard} from "../contracts/mocks/MockPriceGuard.sol";

/// @dev Transfers deliver up to `shortfall` units less; the sender is debited exactly `amount`.
contract Review2ShortToken is ERC20 {
    uint256 public shortfall;

    constructor() ERC20("Short delivery", "SHORT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function slash(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function lostOn(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        return Math.min(shortfall, amount - 1);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount != 0) {
            uint256 lost = lostOn(amount);
            if (lost != 0) super._update(from, address(0), lost);
            amount -= lost;
        }
        super._update(from, to, amount);
    }
}

/// @notice Stateful handler keyed by token ADDRESS (not index), so any component can be removed and
/// re-added at any position. Independent ledger of balances and reserves per token.
contract Review2Handler is CommonBase, StdUtils {
    uint256 internal constant N = 4;
    uint256 internal constant MAX_AMOUNT = 1e24;
    address public constant GOVERNANCE = address(0x60F);
    address public constant REBALANCER = address(0x5EB);

    GRETVault public immutable vault;
    MockERC20 public immutable t0;
    MockERC20 public immutable t1;
    Review2ShortToken public immutable t2;
    MockFaultyERC20 public immutable t3;
    address[4] public actors;
    mapping(address => bool) public everMinted;

    // Ledger keyed by token address.
    mapping(address => uint256) public expBalance;
    mapping(address => uint256) public expReserve;

    // Violations.
    string public violation;
    mapping(bytes32 => uint256) public successes;

    constructor() {
        t0 = new MockERC20("T0", "T0", 18);
        t1 = new MockERC20("T1", "T1", 6);
        t2 = new Review2ShortToken();
        t3 = new MockFaultyERC20("T3", "T3", 18);
        IERC20[] memory c = new IERC20[](4);
        c[0] = IERC20(address(t0));
        c[1] = IERC20(address(t1));
        c[2] = IERC20(address(t2));
        c[3] = IERC20(address(t3));
        uint256[] memory init = new uint256[](4);
        init[0] = 2e18;
        init[1] = 3e6;
        init[2] = 1e18;
        init[3] = 5e18;
        vault = new GRETVault(c, init, GOVERNANCE);
        MockPriceGuard guard = new MockPriceGuard();
        for (uint256 k; k < 4; ++k) actors[k] = address(uint160(0xF2A0 + k));
        vm.startPrank(GOVERNANCE);
        vault.proposeRebalancer(REBALANCER);
        vault.proposePriceGuard(address(guard));
        // The fee recipient is a minter, so zero-supply restarts stay reachable.
        vault.setFeeRecipient(actors[0]);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(REBALANCER);
        vault.acceptRebalancer();
        vault.applyPriceGuard();
        for (uint256 i; i < N; ++i) {
            for (uint256 k; k < 4; ++k) {
                vm.prank(actors[k]);
                _tok(i).approve(address(vault), type(uint256).max);
            }
            vm.prank(REBALANCER);
            _tok(i).approve(address(vault), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _tok(uint256 i) internal view returns (IERC20) {
        if (i == 0) return IERC20(address(t0));
        if (i == 1) return IERC20(address(t1));
        if (i == 2) return IERC20(address(t2));
        return IERC20(address(t3));
    }

    function raw(address token, address who) public view returns (uint256) {
        if (token == address(t3)) return t3.rawBalanceOf(who);
        return IERC20(token).balanceOf(who);
    }

    function _fund(address who, address token, uint256 amount) internal {
        if (token == address(t0)) t0.mint(who, amount);
        else if (token == address(t1)) t1.mint(who, amount);
        else if (token == address(t2)) t2.mint(who, amount);
        else t3.mint(who, amount);
    }

    /// @dev Units that arrive when `amount` is sent.
    function _arrives(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(t2)) return amount - t2.lostOn(amount);
        return amount;
    }

    function _fail(string memory why) internal {
        if (bytes(violation).length == 0) violation = why;
    }

    function _zeros(uint256 n) internal pure returns (uint256[] memory v) {
        v = new uint256[](n);
    }

    function _faultFree() internal view returns (bool) {
        return t3.fault() == MockFaultyERC20.Fault.None && !t3.blocked(address(vault));
    }

    function _checkBacking(address[] memory comps, uint256[] memory rBefore, uint256 sBefore) internal {
        uint256[] memory rAfter = vault.reserves();
        uint256 sAfter = vault.totalSupply();
        if (sBefore == 0 || sAfter == 0) return;
        for (uint256 i; i < comps.length; ++i) {
            if (rAfter[i] * sBefore < rBefore[i] * sAfter) _fail("backing per share decreased");
        }
    }

    // ------------------------------------------------------------------ normal operation

    struct MintCtx {
        address actor;
        uint256 sBefore;
        uint256 expMinted;
        uint256 fee;
        bool any;
        bool healthy;
        uint256 version;
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        if (vault.liquidationActive() || vault.mintPaused()) return;
        MintCtx memory c;
        c.actor = actors[actorSeed % 4];
        address[] memory comps = _components();
        uint256[] memory rBefore = vault.reserves();
        c.sBefore = vault.totalSupply();
        shares = c.sBefore == 0 ? 1e18 : bound(shares, 1, MAX_AMOUNT);
        uint256[] memory amounts;
        try vault.previewMint(shares) returns (uint256[] memory a) {
            amounts = a;
        } catch {
            return;
        }
        uint256[] memory init = vault.initialAmounts();
        c.expMinted = c.sBefore == 0 ? 1e18 : shares;
        for (uint256 i; i < comps.length; ++i) {
            uint256 fair = c.sBefore == 0
                ? init[i]
                : (rBefore[i] == 0 ? 0 : Math.mulDiv(shares, rBefore[i], c.sBefore, Math.Rounding.Ceil));
            if (amounts[i] != fair) _fail("previewMint amount");
            if (fair > 1e40) return;
            if (fair == 0) continue;
            c.any = true;
            _fund(c.actor, comps[i], fair);
            if (c.sBefore != 0) {
                c.expMinted = Math.min(c.expMinted, Math.mulDiv(_arrives(comps[i], fair), c.sBefore, rBefore[i]));
            }
        }
        if (!c.any) c.expMinted = 0;
        c.fee = Math.mulDiv(c.expMinted, vault.mintFee(), 10_000);
        uint256[] memory maxIn = new uint256[](comps.length);
        for (uint256 i; i < comps.length; ++i) maxIn[i] = type(uint256).max;
        c.version = vault.basketVersion();
        c.healthy = _faultFree() && t2.shortfall() == 0;
        vm.prank(c.actor);
        try vault.mint(shares, maxIn, 0, c.version) returns (uint256 issued, uint256[] memory got) {
            _afterMint(c, comps, amounts, rBefore, issued, got);
        } catch {
            // With healthy tokens a mint that would issue shares must not revert.
            if (c.healthy && c.any && c.expMinted != 0 && c.expMinted - c.fee != 0) _fail("healthy mint reverted");
        }
    }

    function _afterMint(
        MintCtx memory c,
        address[] memory comps,
        uint256[] memory amounts,
        uint256[] memory rBefore,
        uint256 issued,
        uint256[] memory got
    ) internal {
        successes[c.sBefore == 0 ? bytes32("restart") : bytes32("mint")]++;
        if (!c.any) _fail("mint without contribution");
        if (issued != c.expMinted - c.fee) _fail("minted amount");
        everMinted[c.actor] = true;
        for (uint256 i; i < comps.length; ++i) {
            uint256 arr = _arrives(comps[i], amounts[i]);
            if (got[i] != arr) _fail("received amount");
            expBalance[comps[i]] += arr;
            expReserve[comps[i]] += arr;
        }
        _checkBacking(comps, rBefore, c.sBefore);
    }

    struct RedeemCtx {
        address actor;
        uint256 sBefore;
        uint256 burned;
        uint256 remaining;
        uint256 version;
        uint256 nSkip;
        bool mustWork;
    }

    function redeem(uint256 actorSeed, uint256 shares, uint256 skipMask, bool all) external {
        if (vault.liquidationActive()) return;
        RedeemCtx memory c;
        c.actor = actors[actorSeed % 4];
        uint256 bal = vault.balanceOf(c.actor);
        if (bal == 0) return;
        shares = all ? bal : bound(shares, 1, bal);
        address[] memory comps = _components();
        uint256[] memory rBefore = vault.reserves();
        c.sBefore = vault.totalSupply();
        (address[] memory skipped, bool[] memory skip) = _skipSet(comps, skipMask);
        c.nSkip = skipped.length;
        c.burned = shares - Math.mulDiv(shares, vault.redeemFee(), 10_000);
        c.remaining = c.sBefore - c.burned;
        c.version = vault.basketVersion();
        // Fault-free tokens that are not skipped: the redemption must go through.
        c.mustWork = everMinted[c.actor] && (c.remaining == 0 || c.remaining >= 1e18)
            && (_faultFree() || _skipsT3(comps, skip));
        vm.prank(c.actor);
        try vault.redeemSkipping(shares, _zeros(comps.length), skipped, c.version) returns (uint256[] memory out) {
            _afterRedeem(c, comps, skip, rBefore, out);
        } catch {
            if (c.mustWork) _fail("exit reverted");
        }
    }

    function _skipSet(address[] memory comps, uint256 skipMask)
        internal
        pure
        returns (address[] memory skipped, bool[] memory skip)
    {
        uint256 nSkip;
        for (uint256 i; i < comps.length; ++i) if ((skipMask >> i) & 1 == 1) ++nSkip;
        bool dup = nSkip != 0 && (skipMask >> 8) & 1 == 1;
        skipped = new address[](nSkip + (dup ? 1 : 0));
        skip = new bool[](comps.length);
        uint256 k;
        for (uint256 i; i < comps.length; ++i) {
            if ((skipMask >> i) & 1 == 1) {
                skipped[k++] = comps[i];
                skip[i] = true;
            }
        }
        if (dup) skipped[k] = skipped[0];
    }

    function _afterRedeem(
        RedeemCtx memory c,
        address[] memory comps,
        bool[] memory skip,
        uint256[] memory rBefore,
        uint256[] memory out
    ) internal {
        successes[c.nSkip == 0 ? bytes32("redeem") : bytes32("redeemSkipping")]++;
        if (c.remaining == 0) successes["redeemToZero"]++;
        if (!everMinted[c.actor]) _fail("redeemed without mint");
        if (c.remaining != 0 && c.remaining < 1e18) _fail("supply below minimum");
        for (uint256 i; i < comps.length; ++i) {
            uint256 share = Math.mulDiv(c.burned, rBefore[i], c.sBefore);
            if (out[i] != (skip[i] ? 0 : share)) _fail("redeem amount");
            expBalance[comps[i]] -= out[i];
            if (skip[i]) {
                if (c.remaining == 0) expReserve[comps[i]] -= share;
            } else {
                expReserve[comps[i]] -= out[i];
            }
        }
        _checkBacking(comps, rBefore, c.sBefore);
    }

    function _skipsT3(address[] memory comps, bool[] memory skip) internal view returns (bool) {
        for (uint256 i; i < comps.length; ++i) {
            if (comps[i] == address(t3)) return skip[i] || vault.reserves()[i] == 0;
        }
        return true;
    }

    function transferShares(uint256 a, uint256 b, uint256 amount) external {
        address from = actors[a % 4];
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        vault.transfer(actors[b % 4], bound(amount, 1, bal));
    }

    function donate(uint256 tokenSeed, uint256 amount) external {
        address token = address(_tok(tokenSeed % N));
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(address(vault), token, amount);
        expBalance[token] += amount;
    }

    /// @dev The issuer takes tokens from the vault; outside liquidation the loss is recognized now.
    function slash(uint256 tokenSeed, uint256 amount) external {
        address token = address(_tok(tokenSeed % N));
        if (token == address(t0) || token == address(t1)) return;
        uint256 held = raw(token, address(vault));
        if (held == 0) return;
        if (token == address(t3) && t3.fault() == MockFaultyERC20.Fault.RevertOnBalanceOf) return;
        amount = bound(amount, 1, held);
        if (token == address(t2)) t2.slash(address(vault), amount);
        else t3.slash(address(vault), amount);
        expBalance[token] -= amount;
        (bool inBasket, uint256 idx) = _find(token);
        if (!vault.liquidationActive() && inBasket) {
            uint256 loss = vault.recognizeLoss(idx);
            uint256 r = expReserve[token];
            uint256 b = held - amount;
            if (loss != (r > b ? r - b : 0)) _fail("loss amount");
            if (r > b) expReserve[token] = b;
        } else if (!inBasket) {
            // nothing
        } else {
            successes["slashInLiquidation"]++;
        }
    }

    function setShortfall(uint256 amount) external {
        t2.setShortfall(amount % 11);
    }

    function setT3Fault(uint256 mode) external {
        MockFaultyERC20.Fault[3] memory modes =
            [MockFaultyERC20.Fault.None, MockFaultyERC20.Fault.RevertOnTransfer, MockFaultyERC20.Fault.RevertOnBalanceOf];
        t3.setFault(modes[mode % 3]);
    }

    // ------------------------------------------------------------------ governance

    function sync(uint256 tokenSeed) external {
        address token = address(_tok(tokenSeed % N));
        (bool inBasket,) = _find(token);
        uint256 rBefore = expReserve[token];
        uint256[] memory owedBefore = _owed();
        vm.prank(GOVERNANCE);
        try vault.sync(token) returns (uint256 added) {
            if (!inBasket) _fail("sync outside basket");
            expReserve[token] = rBefore + added;
            if (added != 0) successes[vault.liquidationActive() ? bytes32("syncLiq") : bytes32("sync")]++;
            if (added != 0) {
                uint256 owedNow = vault.reserves()[_idx(token)] - vault.rightsClaimed()[_idx(token)];
                if (owedNow != raw(token, address(vault))) _fail("sync did not land on balance");
            }
        } catch {}
        owedBefore;
    }

    function rescue(uint256 tokenSeed, uint256 amount, bool overshoot) external {
        address token = address(_tok(tokenSeed % N));
        (bool inBasket, uint256 idx) = _find(token);
        uint256[] memory owedBefore = _owed();
        uint256 limit;
        if (inBasket) {
            try vault.componentSurplus(idx) returns (uint256 s) {
                limit = s;
            } catch {
                return;
            }
        } else {
            limit = raw(token, address(vault));
            if (token == address(t3) && t3.fault() != MockFaultyERC20.Fault.None) return;
        }
        if (vault.writtenOff(token)) limit = 0;
        uint256 ask = overshoot || limit == 0 ? limit + bound(amount, 1, MAX_AMOUNT) : bound(amount, 1, limit);
        vm.prank(GOVERNANCE);
        try vault.rescue(token, GOVERNANCE, ask) {
            if (ask > limit) _fail("rescued beyond surplus");
            expBalance[token] -= ask;
            successes[vault.liquidationActive() ? bytes32("rescueLiq") : bytes32("rescue")]++;
        } catch {}
        uint256[] memory owedAfter = _owed();
        for (uint256 i; i < owedAfter.length; ++i) if (owedAfter[i] != owedBefore[i]) _fail("rescue changed owed");
    }

    /// @dev Sells the whole reserve of a random component (if any) and removes it, at any position.
    function removeAny(uint256 seed) external {
        if (vault.liquidationActive()) return;
        address[] memory comps = _components();
        if (comps.length < 2) return;
        uint256 idx = seed % comps.length;
        address token = comps[idx];
        if (vault.writtenOff(token)) return;
        uint256 r = vault.reserves()[idx];
        if (r != 0) {
            address buy = comps[(idx + 1 + (seed >> 8) % (comps.length - 1)) % comps.length];
            if (!_swapExact(token, r, buy, 1e6 + (seed >> 16) % 1e18)) return;
        }
        uint256 v = vault.basketVersion();
        vm.prank(GOVERNANCE);
        try vault.removeComponent(token) {
            successes["remove"]++;
            if (vault.basketVersion() != v + 1) _fail("version");
            if (expReserve[token] != 0) _fail("removed with reserve");
        } catch {
            _fail("remove of empty component reverted");
        }
    }

    function addBack(uint256 seed) external {
        if (vault.liquidationActive()) return;
        for (uint256 j; j < N; ++j) {
            address token = address(_tok((seed + j) % N));
            (bool inBasket,) = _find(token);
            if (inBasket) continue;
            vm.prank(GOVERNANCE);
            vault.announceComponent(token);
            vm.warp(block.timestamp + 7 days);
            vault.addComponent(token);
            successes["add"]++;
            if (vault.reserves()[_idx(token)] != 0) _fail("added with reserve");
            return;
        }
    }

    function swap(uint256 sellSeed, uint256 buySeed, uint256 sellAmount, uint256 buyAmount) external {
        if (vault.liquidationActive()) return;
        address[] memory comps = _components();
        if (comps.length < 2) return;
        uint256 s = sellSeed % comps.length;
        uint256 b = (s + 1 + buySeed % (comps.length - 1)) % comps.length;
        uint256 r = vault.reserves()[s];
        if (r == 0) return;
        _swapExact(comps[s], bound(sellAmount, 1, r), comps[b], bound(buyAmount, 1, MAX_AMOUNT));
    }

    function _swapExact(address sell, uint256 sellAmount, address buy, uint256 buyAmount) internal returns (bool) {
        _fund(REBALANCER, buy, buyAmount);
        address[] memory comps = _components();
        uint256[] memory rBefore = vault.reserves();
        uint256 sellIdx = _idx(sell);
        uint256 buyIdx = _idx(buy);
        vm.prank(REBALANCER);
        try vault.swap(sell, sellAmount, buy, buyAmount) returns (uint256 got) {
            successes["swap"]++;
            uint256 arr = _arrives(buy, buyAmount);
            if (got != arr) _fail("swap received");
            expBalance[buy] += arr;
            expReserve[buy] += arr;
            expBalance[sell] -= sellAmount;
            expReserve[sell] -= sellAmount;
            uint256[] memory rAfter = vault.reserves();
            for (uint256 i; i < comps.length; ++i) {
                if (i != sellIdx && i != buyIdx && rAfter[i] != rBefore[i]) _fail("swap touched other reserve");
            }
            return true;
        } catch {
            return false;
        }
    }

    function writeOff(uint256 seed) external {
        if (vault.liquidationActive() || seed % 3 != 0) return;
        address[] memory comps = _components();
        uint256 idx = (seed >> 4) % comps.length;
        address token = comps[idx];
        uint256 r = vault.reserves()[idx];
        if (r == 0) return;
        vm.prank(GOVERNANCE);
        vault.proposeWriteOff(token);
        vm.warp(block.timestamp + 7 days);
        // The fault may have moved positions? No: no removal in between.
        vault.writeOffComponent(token);
        successes["writeOff"]++;
        expReserve[token] = 0;
        if (vault.initialAmounts()[idx] != 0) _fail("write-off kept initial amount");
    }

    function setInitialAmounts(uint256 seed) external {
        address[] memory comps = _components();
        uint256[] memory a = new uint256[](comps.length);
        bool positive;
        for (uint256 i; i < comps.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 3 == 0) continue;
            a[i] = 1 + r % 1e20;
            positive = true;
        }
        uint256 v = vault.basketVersion();
        vm.prank(GOVERNANCE);
        try vault.setInitialAmounts(a, v) {
            if (!positive) _fail("empty initial amounts accepted");
            successes["setInitial"]++;
        } catch {}
    }

    function setFees(uint256 m, uint256 r) external {
        m = bound(m, 0, 500);
        r = bound(r, 0, 500);
        vm.prank(GOVERNANCE);
        vault.proposeFees(m, r);
        if (vault.pendingFeesReadyAt() != 0) {
            vm.warp(block.timestamp + 7 days);
            vault.applyFees();
        }
    }

    function activate(uint256 seed) external {
        if (vault.liquidationActive() || seed % 12 != 0) return;
        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        successes["activate"]++;
    }

    function convert(uint256 a, uint256 amount) external {
        if (!vault.liquidationActive()) return;
        address actor = actors[a % 4];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        vm.prank(actor);
        vault.convertToClaims(bound(amount, 1, bal));
    }

    function claim(uint256 a, uint256 idxSeed, uint256 toSeed) external {
        if (!vault.liquidationActive()) return;
        address actor = actors[a % 4];
        address[] memory comps = _components();
        uint256 idx = idxSeed % comps.length;
        address token = comps[idx];
        address to = actors[toSeed % 4];
        uint256 pending = vault.claimable(actor, idx);
        uint256 rights = vault.pendingRights(actor, idx);
        bool works = token != address(t3) || _faultFree();
        uint256 sent = pending;
        vm.prank(actor);
        try vault.claim(idx, to, 0) returns (uint256 amount) {
            successes["claim"]++;
            if (amount != pending) _fail("claim amount");
            expBalance[token] -= sent;
            if (vault.pendingRights(actor, idx) != 0) _fail("rights left after claim");
        } catch {
            if (works && pending != 0) _fail("healthy claim reverted");
            if (vault.pendingRights(actor, idx) != rights) _fail("failed claim moved rights");
        }
    }

    // ------------------------------------------------------------------ views

    function _components() internal view returns (address[] memory out) {
        IERC20[] memory c = vault.components();
        out = new address[](c.length);
        for (uint256 i; i < c.length; ++i) out[i] = address(c[i]);
    }

    function _find(address token) internal view returns (bool, uint256) {
        address[] memory c = _components();
        for (uint256 i; i < c.length; ++i) if (c[i] == token) return (true, i);
        return (false, 0);
    }

    function _idx(address token) internal view returns (uint256 i) {
        bool ok;
        (ok, i) = _find(token);
        require(ok, "not in basket");
    }

    function _owed() internal view returns (uint256[] memory owed) {
        uint256[] memory r = vault.reserves();
        uint256[] memory c = vault.rightsClaimed();
        owed = new uint256[](r.length);
        for (uint256 i; i < r.length; ++i) owed[i] = r[i] - c[i];
    }

    function components() external view returns (address[] memory) {
        return _components();
    }

    function token(uint256 i) external view returns (address) {
        return address(_tok(i));
    }

    function actor(uint256 k) external view returns (address) {
        return actors[k];
    }
}

contract Review2InvariantTest is Test {
    Review2Handler internal h;
    GRETVault internal vault;

    function setUp() public {
        h = new Review2Handler();
        vault = h.vault();
        bytes4[] memory s = new bytes4[](20);
        s[0] = Review2Handler.mint.selector;
        s[1] = Review2Handler.redeem.selector;
        s[2] = Review2Handler.transferShares.selector;
        s[3] = Review2Handler.donate.selector;
        s[4] = Review2Handler.slash.selector;
        s[5] = Review2Handler.setShortfall.selector;
        s[6] = Review2Handler.setT3Fault.selector;
        s[7] = Review2Handler.sync.selector;
        s[8] = Review2Handler.rescue.selector;
        s[9] = Review2Handler.removeAny.selector;
        s[10] = Review2Handler.addBack.selector;
        s[11] = Review2Handler.swap.selector;
        s[12] = Review2Handler.writeOff.selector;
        s[13] = Review2Handler.setInitialAmounts.selector;
        s[14] = Review2Handler.setFees.selector;
        s[15] = Review2Handler.activate.selector;
        s[16] = Review2Handler.convert.selector;
        s[17] = Review2Handler.claim.selector;
        s[18] = Review2Handler.mint.selector;
        s[19] = Review2Handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
        targetContract(address(h));
    }

    function invariant_noViolation() public view {
        assertEq(h.violation(), "", "handler violation");
    }

    function invariant_ledger() public view {
        for (uint256 i; i < 4; ++i) {
            address token = h.token(i);
            assertEq(h.raw(token, address(vault)), h.expBalance(token), "balance ledger");
        }
        address[] memory comps = h.components();
        uint256[] memory r = vault.reserves();
        for (uint256 i; i < comps.length; ++i) {
            assertEq(r[i], h.expReserve(comps[i]), "reserve ledger");
        }
        if (comps.length < 4) {
            for (uint256 i; i < 4; ++i) {
                bool found;
                for (uint256 j; j < comps.length; ++j) if (comps[j] == h.token(i)) found = true;
                if (!found) assertEq(h.expReserve(h.token(i)), 0, "reserve outside basket");
            }
        }
    }

    function invariant_supplyAndGret() public view {
        assertEq(vault.balanceOf(address(vault)), 0, "vault holds GRET");
        if (vault.liquidationActive()) return;
        uint256 supply = vault.totalSupply();
        assertTrue(supply == 0 || supply >= 1e18, "supply in (0, MIN)");
        uint256[] memory r = vault.reserves();
        if (supply == 0) for (uint256 i; i < r.length; ++i) assertEq(r[i], 0, "reserve without supply");
    }

    /// Normal operation: every reserve is covered by the balance (losses are recognized at once in
    /// this handler, T2 and T3 never debit the vault more than they report).
    function invariant_reservesCovered() public view {
        address[] memory comps = h.components();
        uint256[] memory r = vault.reserves();
        uint256[] memory rc = vault.rightsClaimed();
        uint256[] memory tc = vault.totalClaimed();
        for (uint256 i; i < comps.length; ++i) {
            assertLe(rc[i], r[i], "rights above reserve");
            assertLe(tc[i], rc[i], "paid above rights");
            if (!vault.liquidationActive()) assertGe(h.raw(comps[i], address(vault)), r[i], "insolvent");
        }
    }

    /// Liquidation: all potential rights (converted and still-held GRET) fit within what is owed,
    /// and the sum of claimable payouts fits within the balance.
    function invariant_liquidationSolvent() public view {
        if (!vault.liquidationActive()) return;
        address[] memory comps = h.components();
        uint256[] memory r = vault.reserves();
        uint256[] memory rc = vault.rightsClaimed();
        uint256 L = vault.liquidationSupply();
        uint256 sharesSum = vault.totalSupply();
        for (uint256 k; k < 4; ++k) sharesSum += vault.claimShares(h.actor(k));
        assertEq(sharesSum, L, "shares add up");
        for (uint256 i; i < comps.length; ++i) {
            uint256 potential;
            uint256 payable_;
            for (uint256 k; k < 4; ++k) {
                address a = h.actor(k);
                uint256 total = vault.claimShares(a) + vault.balanceOf(a);
                if (total != 0) potential += Math.mulDiv(total, r[i], L) - vault.claimed(a, i);
                if (comps[i] != h.token(3) || h.t3().fault() != MockFaultyERC20.Fault.RevertOnBalanceOf) {
                    payable_ += vault.claimable(a, i);
                }
            }
            assertLe(potential, r[i] - rc[i], "potential rights above owed");
            if (comps[i] != h.token(3) || h.t3().fault() != MockFaultyERC20.Fault.RevertOnBalanceOf) {
                assertLe(payable_, h.raw(comps[i], address(vault)), "claimable above balance");
            }
        }
    }

    function invariant_callSummary() public view {
        // Reported through the handler's counters; nothing to assert here.
    }
}
