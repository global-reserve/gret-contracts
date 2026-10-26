// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IPriceGuard} from "../IPriceGuard.sol";

interface IReserves {
    function reserves() external view returns (uint256[] memory);
}

/// @notice Test-only price guard that accepts every swap unless told to refuse, and records the
/// last one with the reserves the vault reported during the call.
contract MockPriceGuard is IPriceGuard {
    bool public refuse;
    uint256 public calls;
    address public lastSell;
    uint256 public lastSellAmount;
    address public lastBuy;
    uint256 public lastReceived;
    uint256[] private _reservesSeen;

    error SwapRefused();

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function checkSwap(address sell, uint256 sellAmount, address buy, uint256 received) external {
        if (refuse) revert SwapRefused();
        ++calls;
        lastSell = sell;
        lastSellAmount = sellAmount;
        lastBuy = buy;
        lastReceived = received;
        _reservesSeen = IReserves(msg.sender).reserves();
    }

    function reservesSeen() external view returns (uint256[] memory) {
        return _reservesSeen;
    }
}
