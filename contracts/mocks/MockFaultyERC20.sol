// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC-20 whose failure mode can be switched at any time.
/// @dev Models adverse component behavior for vault tests; not any real issuer's token.
contract MockFaultyERC20 is ERC20 {
    enum Fault {
        None,
        RevertOnTransfer,
        ReturnFalseOnTransfer,
        RevertOnBalanceOf,
        FeeOnTransfer,
        Reenter,
        RevertOnZeroTransfer,
        ShortByOneOnTransfer
    }

    uint256 public constant FEE_BPS = 100;

    uint8 private immutable _mockDecimals;
    Fault public fault;
    address public reentryTarget;
    bytes public reentryData;
    /// @notice Addresses the "issuer" froze: they can neither send nor receive.
    mapping(address account => bool) public blocked;

    error TransfersBlocked();
    error BalanceOfBlocked();
    error ZeroTransfer();
    error AccountBlocked(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _mockDecimals = decimals_;
    }

    function setFault(Fault fault_) external {
        fault = fault_;
    }

    /// @notice On the next transfer, calls `target` with `data` and bubbles up any revert.
    function setReentry(address target, bytes calldata data) external {
        fault = Fault.Reenter;
        reentryTarget = target;
        reentryData = data;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Removes tokens from `account` without its consent, like a negative rebase.
    function slash(address account, uint256 amount) external {
        _burn(account, amount);
    }

    /// @notice Balance that ignores the configured fault, for test assertions.
    function rawBalanceOf(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (fault == Fault.RevertOnBalanceOf) revert BalanceOfBlocked();
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (fault == Fault.RevertOnTransfer) revert TransfersBlocked();
        if (fault == Fault.ReturnFalseOnTransfer) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (fault == Fault.RevertOnTransfer) revert TransfersBlocked();
        if (fault == Fault.ReturnFalseOnTransfer) return false;
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        bool isTransfer = from != address(0) && to != address(0);
        if (isTransfer) {
            if (blocked[from]) revert AccountBlocked(from);
            if (blocked[to]) revert AccountBlocked(to);
            if (value == 0 && fault == Fault.RevertOnZeroTransfer) revert ZeroTransfer();
        }
        if (isTransfer && fault == Fault.FeeOnTransfer) {
            uint256 fee = value * FEE_BPS / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        // Like tokens that convert amounts to internal shares (xStocks): one unit lost to rounding.
        if (isTransfer && fault == Fault.ShortByOneOnTransfer && value > 1) {
            super._update(from, address(0), 1);
            value -= 1;
        }
        super._update(from, to, value);

        if (isTransfer && fault == Fault.Reenter) {
            fault = Fault.None;
            (bool ok, bytes memory result) = reentryTarget.call(reentryData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }
}
