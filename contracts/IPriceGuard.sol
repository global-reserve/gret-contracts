// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title Price guard of the GRET vault
/// @notice Prices every swap the vault's rebalancer makes and refuses the ones that lose too much.
interface IPriceGuard {
    /// @notice Reverts unless the vault may give `sellAmount` of `sell` for the `received` units of
    /// `buy` that arrived. Called after receipt, before sending sell tokens. The guard must exclude
    /// `received` from the buy balance when valuing pre-swap backing, and omit excluded components.
    /// Accounting views guarded against reentrancy are unavailable during this call.
    function checkSwap(address sell, uint256 sellAmount, address buy, uint256 received) external;
}
