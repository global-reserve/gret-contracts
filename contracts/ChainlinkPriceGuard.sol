// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceGuard} from "./IPriceGuard.sol";

/// @dev The part of Chainlink's `AggregatorV3Interface` the guard reads.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @dev The vault views the guard reads to value the vault and to continue the week's count.
interface IGRETVaultView {
    function components() external view returns (address[] memory);

    function excluded(address token) external view returns (bool);

    function previousPriceGuard() external view returns (address);
}

/// @title Chainlink price guard of the GRET vault
/// @notice Values both sides of every swap in US dollars with Chainlink feeds. It refuses a swap
/// that loses more than 2% of what the vault sells, or one that would make the week's swaps take
/// more than 2% of the vault's priced backing: its active, readable components with a feed. Each
/// loss counts as its share of that backing when it happens, which is at least what every GRET
/// loses, so mints and redemptions in between do not stretch the limit. A token without a feed,
/// whose price is stale, or whose decimals changed after the guard was deployed, cannot be swapped.
/// It has no owner: tokens, feeds and limits are fixed at deployment. Changing them means deploying
/// another guard, which the vault applies only after its seven-day wait. A replacement continues
/// the week's count of the guard it replaced, so it does not open a second budget.
/// @dev Each feed must quote one whole token in US dollars, with nothing to convert. A loss the
/// feeds do not see, such as a token that trades below the asset its feed prices, is not limited.
/// Neither is a split or a multiplier change that alters what one unit of a token is worth before
/// its feed prices the new unit: governance revokes the rebalancer around such changes. Mint,
/// redemption and liquidation never call the guard.
contract ChainlinkPriceGuard is IPriceGuard {
    /// @notice Highest loss of a single swap, in basis points of the value sold: 2%.
    uint256 public constant MAX_SWAP_LOSS = 200;
    /// @notice Highest share of the vault's priced backing that all swaps in a week can take, in
    /// basis points: 2%. Each loss is measured against that backing just before the swap.
    uint256 public constant MAX_WEEKLY_LOSS = 200;
    /// @notice Weeks are fixed periods of this length, counted from the Unix epoch.
    uint256 public constant WEEK = 7 days;
    uint256 private constant BPS = 10_000;
    /// @dev Gas for each balance read, each read of the predecessor's count and each valuation in
    /// `_vaultValue`, far above what tokens and feeds need, so that no single contract can take the
    /// gas of the whole swap.
    uint256 private constant READ_GAS = 200_000;
    /// @dev `MAX_WEEKLY_LOSS` as a share with 18 decimals.
    uint256 private constant WEEKLY_LIMIT = MAX_WEEKLY_LOSS * 1e18 / BPS;

    struct PriceFeed {
        IChainlinkFeed feed;
        /// @dev Oldest price accepted, in seconds since its last update.
        uint256 maxAge;
        /// @dev Read at deployment; a token whose decimals later differ is refused.
        uint8 tokenDecimals;
    }

    /// @notice The only caller of `checkSwap`.
    address public immutable vault;
    mapping(address token => PriceFeed) private _feeds;

    /// @notice Week of the last recorded loss.
    uint256 public currentWeek;
    /// @notice Share of the vault's priced backing that swaps took in `currentWeek`, with 18
    /// decimals (1e18 is all of it): the sum of each loss divided by that backing just before it.
    uint256 public weeklyLoss;

    /// @param loss In US dollars with 18 decimals.
    /// @param vaultValue The vault's priced reserves just before the swap, in US dollars.
    /// @param weeklyLoss The week's share so far, including this loss.
    event LossRecorded(
        address indexed sold,
        address indexed bought,
        uint256 loss,
        uint256 vaultValue,
        uint256 weeklyLoss
    );

    error NotAContract(address account);
    error LengthMismatch();
    error ZeroMaxAge(address token);
    error DuplicateToken(address token);
    error NotVault(address caller);
    error NoFeed(address token);
    error InvalidPrice(address token, int256 answer);
    error StalePrice(address token, uint256 updatedAt);
    error DecimalsChanged(address token, uint8 expected, uint8 current);
    error SwapLossTooHigh(uint256 soldValue, uint256 boughtValue);
    error WeeklyLossTooHigh(uint256 weeklyLoss, uint256 limit);

    constructor(
        address vault_,
        address[] memory tokens,
        IChainlinkFeed[] memory feeds,
        uint256[] memory maxAges
    ) {
        if (vault_.code.length == 0) revert NotAContract(vault_);
        uint256 count = tokens.length;
        if (feeds.length != count || maxAges.length != count) revert LengthMismatch();
        for (uint256 i; i < count; ++i) {
            address token = tokens[i];
            if (token.code.length == 0) revert NotAContract(token);
            if (address(feeds[i]).code.length == 0) revert NotAContract(address(feeds[i]));
            if (maxAges[i] == 0) revert ZeroMaxAge(token);
            if (address(_feeds[token].feed) != address(0)) revert DuplicateToken(token);
            _feeds[token] = PriceFeed(feeds[i], maxAges[i], IERC20Metadata(token).decimals());
        }
        vault = vault_;
    }

    /// @inheritdoc IPriceGuard
    /// @dev Prices come from the feeds only, so the rebalancer's data is ignored.
    function checkSwap(
        address sell,
        uint256 sellAmount,
        address buy,
        uint256 received,
        bytes calldata
    ) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        // What leaves is valued up and what arrives down, so rounding never hides a loss.
        uint256 soldValue = _value(sell, sellAmount, Math.Rounding.Ceil);
        uint256 boughtValue = _value(buy, received, Math.Rounding.Floor);
        if (boughtValue >= soldValue) return;

        uint256 loss = soldValue - boughtValue;
        if (loss * BPS > soldValue * MAX_SWAP_LOSS) revert SwapLossTooHigh(soldValue, boughtValue);
        uint256 week = block.timestamp / WEEK;
        if (week != currentWeek) {
            // Asked before the new week is stored: a guard applied again as its own successor then
            // reports its last week, which is not this one, and inherits nothing.
            uint256 inherited = _inheritedLoss(week);
            currentWeek = week;
            weeklyLoss = inherited;
        }
        // Buy tokens have arrived and sell tokens have not left. Exclude the receipt so the
        // denominator is pre-swap backing, not both sides of the exchange.
        uint256 vaultValue = _vaultValue(buy, received);
        uint256 total = weeklyLoss + Math.mulDiv(loss, 1e18, vaultValue, Math.Rounding.Ceil);
        if (total > WEEKLY_LIMIT) revert WeeklyLossTooHigh(total, WEEKLY_LIMIT);
        weeklyLoss = total;
        emit LossRecorded(sell, buy, loss, vaultValue, total);
    }

    /// @notice Value of `amount` units of `token` in US dollars with 18 decimals, rounded down.
    /// Reverts if the token has no feed, its price is stale or not positive, or its decimals
    /// differ from those read at deployment.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        return _value(token, amount, Math.Rounding.Floor);
    }

    function priceFeed(address token) external view returns (address feed, uint256 maxAge) {
        PriceFeed storage config = _feeds[token];
        return (address(config.feed), config.maxAge);
    }

    function _value(address token, uint256 amount, Math.Rounding rounding)
        private
        view
        returns (uint256)
    {
        PriceFeed storage config = _feeds[token];
        IChainlinkFeed feed = config.feed;
        if (address(feed) == address(0)) revert NoFeed(token);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (
            updatedAt == 0 || updatedAt > block.timestamp
                || block.timestamp - updatedAt > config.maxAge
        ) {
            revert StalePrice(token, updatedAt);
        }
        // An issuer that changes the decimals changes what one unit is worth, so the cached scale
        // would misprice every amount by a power of ten.
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals != config.tokenDecimals) {
            revert DecimalsChanged(token, config.tokenDecimals, tokenDecimals);
        }
        uint256 scale = 10 ** (uint256(tokenDecimals) + feed.decimals());
        return Math.mulDiv(amount, uint256(answer) * 1e18, scale, rounding);
    }

    /// @dev The loss the guard this one replaced recorded in `week`. The vault's seven-day wait
    /// lets at most one replacement take effect per week, so one predecessor is enough. A
    /// predecessor that reports another week, answers with malformed data or needs more than
    /// `READ_GAS` counts as zero.
    function _inheritedLoss(uint256 week) private view returns (uint256) {
        address previous = IGRETVaultView(vault).previousPriceGuard();
        if (previous == address(0)) return 0;
        (bool ok, uint256 size, uint256 answer) =
            _readWord(previous, abi.encodeCall(this.currentWeek, ()));
        if (!ok || size != 32 || answer != week) return 0;
        (ok, size, answer) = _readWord(previous, abi.encodeCall(this.weeklyLoss, ()));
        if (!ok || size != 32) return 0;
        return answer;
    }

    /// @dev Live active backing immediately before the swap: the incoming buy amount is removed in
    /// token units before valuation. Each unreadable or unpriced component counts as zero, whether
    /// its balance read reverts, answers with less than one word or needs more than `READ_GAS`, its
    /// price is unusable, its decimals changed or its valuation needs more than `READ_GAS`.
    function _vaultValue(address buy, uint256 received) private view returns (uint256 total) {
        address[] memory tokens = IGRETVaultView(vault).components();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (address(_feeds[token].feed) == address(0)) continue;
            if (IGRETVaultView(vault).excluded(token)) continue;
            (bool ok, uint256 size, uint256 balance) =
                _readWord(token, abi.encodeCall(IERC20.balanceOf, (vault)));
            if (!ok || size < 32) continue;
            if (token == buy) balance = Math.saturatingSub(balance, received);
            try this.valueOf{gas: READ_GAS}(token, balance) returns (uint256 value) {
                total += value;
            } catch {}
        }
    }

    /// @dev Calls `target` with `query` and at most `READ_GAS`, copying only the first word of the
    /// answer, so that an oversized answer cannot exhaust the swap's gas. Also returns the answer's
    /// full size, for the caller to check.
    function _readWord(address target, bytes memory query)
        private
        view
        returns (bool ok, uint256 size, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(READ_GAS, target, add(query, 0x20), mload(query), 0, 0x20)
            size := returndatasize()
            word := mload(0)
        }
    }
}
