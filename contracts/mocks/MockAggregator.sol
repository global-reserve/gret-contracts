// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice Test-only Chainlink feed whose price and update time are set by hand.
contract MockAggregator {
    uint8 public immutable decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 answer) {
        decimals = decimals_;
        setAnswer(answer);
    }

    /// @notice Sets the price as updated now.
    function setAnswer(int256 answer) public {
        setRound(answer, block.timestamp);
    }

    function setRound(int256 answer, uint256 updatedAt) public {
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
