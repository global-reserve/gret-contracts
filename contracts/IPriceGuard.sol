// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title Price guard of the GRET vault
/// @notice Prices every swap the vault's rebalancer makes and refuses the ones that lose too much.
interface IPriceGuard {
    /// @notice Reverts unless the vault may give `sellAmount` of `sell` for the `received` units of
    /// `buy` that arrived. The vault calls it in every swap, before updating its reserves, so the
    /// guard sees them as they were before the exchange. The guard may record the swap.
    function checkSwap(address sell, uint256 sellAmount, address buy, uint256 received) external;
}
