// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title Eligibility contract of the GRET vault
/// @notice Decides who may mint and redeem GRET, once governance appoints it; without one, anyone
/// may. The vault asks with a read-only call, and anything but an explicit `true` refuses.
interface IEligibility {
    /// @notice Whether `caller` may pay for a mint whose GRET goes to `receiver`.
    function canMint(address caller, address receiver) external view returns (bool);

    /// @notice Whether `caller` may burn GRET for components that go to `receiver`.
    function canRedeem(address caller, address receiver) external view returns (bool);
}
