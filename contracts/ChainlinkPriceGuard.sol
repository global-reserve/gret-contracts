// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceGuard} from "./IPriceGuard.sol";

/// @dev The part of Chainlink's `AggregatorV3Interface` the guard reads.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev The vault views the guard reads to value the vault.
interface IGRETVaultReserves {
    function components() external view returns (address[] memory);

    function reserves() external view returns (uint256[] memory);
}

/// @title Chainlink price guard of the GRET vault
/// @notice Values both sides of every swap in US dollars with Chainlink feeds. It refuses a swap
/// that loses more than 2% of what the vault sells, or one that would make the week's swaps take
/// more than 2% of the vault's value. Each loss counts as the share of the vault it takes when it
/// happens, which is what every GRET loses, so mints and redemptions in between do not stretch the
/// limit. A token without a feed, or whose price is stale, cannot be swapped.
/// It has no owner: tokens, feeds and limits are fixed at deployment. Changing them means
/// deploying another guard, which the vault applies only after its seven-day wait.
/// @dev Each feed must quote one whole token in US dollars, with nothing to convert. A loss the
/// feeds do not see, such as a token that trades below the asset its feed prices, is not limited.
/// Mint, redemption and liquidation never call the guard.
contract ChainlinkPriceGuard is IPriceGuard {
    /// @notice Highest loss of a single swap, in basis points of the value sold: 2%.
    uint256 public constant MAX_SWAP_LOSS = 200;
    /// @notice Highest share of the vault's value that all swaps in a week can take, in basis points:
    /// 2%. Each loss is measured against the vault's value just before that swap.
    uint256 public constant MAX_WEEKLY_LOSS = 200;
    /// @notice Weeks are fixed periods of this length, counted from the Unix epoch.
    uint256 public constant WEEK = 7 days;
    uint256 private constant BPS = 10_000;
    /// @dev `MAX_WEEKLY_LOSS` as a share with 18 decimals.
    uint256 private constant WEEKLY_LIMIT = MAX_WEEKLY_LOSS * 1e18 / BPS;

    struct PriceFeed {
        IChainlinkFeed feed;
        /// @dev Oldest price accepted, in seconds since its last update.
        uint256 maxAge;
        uint8 tokenDecimals;
    }

    /// @notice The only caller of `checkSwap`.
    address public immutable vault;
    mapping(address token => PriceFeed) private _feeds;

    /// @notice Week of the last recorded loss.
    uint256 public currentWeek;
    /// @notice Share of the vault's value that swaps took in `currentWeek`, with 18 decimals
    /// (1e18 is all of it): the sum of each loss divided by the vault's value just before it.
    uint256 public weeklyLoss;

    /// @param loss In US dollars with 18 decimals.
    /// @param vaultValue The vault's priced reserves just before the swap, in US dollars.
    /// @param weeklyLoss The week's share so far, including this loss.
    event LossRecorded(
        address indexed sold, address indexed bought, uint256 loss, uint256 vaultValue, uint256 weeklyLoss
    );

    error NotAContract(address account);
    error LengthMismatch();
    error ZeroMaxAge(address token);
    error DuplicateToken(address token);
    error NotVault(address caller);
    error NoFeed(address token);
    error InvalidPrice(address token, int256 answer);
    error StalePrice(address token, uint256 updatedAt);
    error SwapLossTooHigh(uint256 soldValue, uint256 boughtValue);
    error WeeklyLossTooHigh(uint256 weeklyLoss, uint256 limit);

    constructor(address vault_, address[] memory tokens, IChainlinkFeed[] memory feeds, uint256[] memory maxAges) {
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
    function checkSwap(address sell, uint256 sellAmount, address buy, uint256 received) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        // What leaves is valued up and what arrives down, so rounding never hides a loss.
        uint256 soldValue = _value(sell, sellAmount, Math.Rounding.Ceil);
        uint256 boughtValue = _value(buy, received, Math.Rounding.Floor);
        if (boughtValue >= soldValue) return;

        uint256 loss = soldValue - boughtValue;
        if (loss * BPS > soldValue * MAX_SWAP_LOSS) revert SwapLossTooHigh(soldValue, boughtValue);
        uint256 week = block.timestamp / WEEK;
        if (week != currentWeek) {
            currentWeek = week;
            weeklyLoss = 0;
        }
        // The vault calls before updating its reserves, so this is its value before the swap. It
        // includes the reserve being sold, so it is positive whenever there is a loss.
        uint256 vaultValue = _vaultValue();
        uint256 total = weeklyLoss + Math.mulDiv(loss, 1e18, vaultValue, Math.Rounding.Ceil);
        if (total > WEEKLY_LIMIT) revert WeeklyLossTooHigh(total, WEEKLY_LIMIT);
        weeklyLoss = total;
        emit LossRecorded(sell, buy, loss, vaultValue, total);
    }

    /// @notice Value of `amount` units of `token` in US dollars with 18 decimals, rounded down.
    /// Reverts if the token has no feed or its price is stale or not positive.
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        return _value(token, amount, Math.Rounding.Floor);
    }

    function priceFeed(address token) external view returns (address feed, uint256 maxAge) {
        PriceFeed storage config = _feeds[token];
        return (address(config.feed), config.maxAge);
    }

    function _value(address token, uint256 amount, Math.Rounding rounding) private view returns (uint256) {
        PriceFeed storage config = _feeds[token];
        IChainlinkFeed feed = config.feed;
        if (address(feed) == address(0)) revert NoFeed(token);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > config.maxAge) {
            revert StalePrice(token, updatedAt);
        }
        uint256 scale = 10 ** (uint256(config.tokenDecimals) + feed.decimals());
        return Math.mulDiv(amount, uint256(answer) * 1e18, scale, rounding);
    }

    /// @dev What backs GRET at current prices: each component at the lesser of its recognized
    /// reserve and the vault's actual balance, so neither a loss nobody has recognized yet nor
    /// tokens that are not reserve (a donation, what the swap just brought in) count. A component
    /// the guard cannot price, or whose balance cannot be read, counts as zero, which only makes
    /// each loss count for more.
    function _vaultValue() private view returns (uint256 total) {
        address[] memory tokens = IGRETVaultReserves(vault).components();
        uint256[] memory amounts = IGRETVaultReserves(vault).reserves();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (amounts[i] == 0 || address(_feeds[token].feed) == address(0)) continue;
            try IERC20Metadata(token).balanceOf(vault) returns (uint256 balance) {
                try this.valueOf(token, Math.min(amounts[i], balance)) returns (uint256 value) {
                    total += value;
                } catch {}
            } catch {}
        }
    }
}
