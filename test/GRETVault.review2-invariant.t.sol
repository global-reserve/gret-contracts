// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {GRETVaultInvariantTest} from "./GRETVault.invariant.t.sol";

/// @notice Start in liquidation with two converted holders, an excluded component and
/// a consumed claim, so every generated sequence exercises recovery and pending rights.
contract Review2InvariantTest is GRETVaultInvariantTest {
    function setUp() public override {
        super.setUp();
        handler.mint(1, 1e18);
        handler.component(2, 2);
        handler.liquidate(0);
        handler.convert(0, 1e18);
        handler.convert(1, 1e18);
        handler.claim(0, 0);
    }
}
