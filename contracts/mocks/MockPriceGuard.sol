// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPriceGuard} from "../IPriceGuard.sol";

interface IReserves {
    function components() external view returns (IERC20[] memory);
    function excluded(address token) external view returns (bool);
}

/// @notice Test-only price guard that accepts every swap unless told to refuse, and records the
/// last one with the vault's active balances before the purchase, as read during the call.
contract MockPriceGuard is IPriceGuard {
    bool public refuse;
    uint256 public calls;
    address public lastSell;
    uint256 public lastSellAmount;
    address public lastBuy;
    uint256 public lastReceived;
    bytes public lastData;
    uint256[] private _reservesSeen;

    error SwapRefused();

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function checkSwap(
        address sell,
        uint256 sellAmount,
        address buy,
        uint256 received,
        bytes calldata data
    ) external {
        if (refuse) revert SwapRefused();
        ++calls;
        lastSell = sell;
        lastSellAmount = sellAmount;
        lastBuy = buy;
        lastReceived = received;
        lastData = data;
        IERC20[] memory tokens = IReserves(msg.sender).components();
        delete _reservesSeen;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 balance = IReserves(msg.sender).excluded(address(tokens[i])) ? 0 : tokens[i].balanceOf(msg.sender);
            if (address(tokens[i]) == buy) balance = balance > received ? balance - received : 0;
            _reservesSeen.push(balance);
        }
    }

    function reservesSeen() external view returns (uint256[] memory) {
        return _reservesSeen;
    }
}
