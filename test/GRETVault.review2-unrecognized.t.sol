// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {GRETVaultInvariantTest} from "./GRETVault.invariant.t.sol";

/// @notice Begin with income, a loss, an exclusion and a new inactive component.
/// Subsequent operations must conserve physical assets without any recognition step.
contract Review2UnrecognizedTest is GRETVaultInvariantTest {
    function setUp() public override {
        super.setUp();
        handler.donate(0, 50e18);
        handler.slash(1, 40_000);
        handler.component(2, 2);
        handler.changeBasket(true);
        handler.donate(3, 1e18);
    }
}
