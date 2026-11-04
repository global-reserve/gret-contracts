// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {GRETVault} from "../contracts/GRETVault.sol";
import {MockEligibility} from "../contracts/mocks/MockEligibility.sol";
import {GRETVaultCase} from "./helpers/GRETVaultCase.sol";

/// @notice The optional eligibility contract: who may mint and redeem once governance appoints
/// one, after the seven-day notice; without one, anyone may.
contract GRETVaultEligibilityTest is GRETVaultCase {
    MockEligibility private policy;

    function _appointPolicy() private {
        policy = new MockEligibility();
        vm.prank(GOVERNANCE);
        vault.proposeEligibility(address(policy));
        vm.warp(block.timestamp + 7 days);
        vault.applyEligibility();
    }

    function _expectNotEligible(address caller, address receiver) private {
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotEligible.selector, caller, receiver));
    }

    function test_withoutEligibilityAnyoneMintsAndRedeems() public {
        assertEq(address(vault.eligibility()), address(0));
        vm.prank(BOB);
        vault.mint(SHARE, CAROL, _pair(2e18, 5e18), SHARE, 0);
        vm.prank(CAROL);
        vault.redeem(SHARE, CAROL, _pair(0, 0), 0);
        assertEq(healthy.balanceOf(CAROL), 2e18);
    }

    /// The notice lets holders the contract would refuse redeem first; anyone applies it after.
    function test_appointmentWaitsSevenDaysAndAnyoneApplies() public {
        policy = new MockEligibility();
        vm.prank(GOVERNANCE);
        vault.proposeEligibility(address(policy));
        (address next, uint256 readyAt) = vault.eligibilityProposal();
        assertEq(next, address(policy));
        assertEq(readyAt, block.timestamp + 7 days);

        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotReady.selector, readyAt));
        vault.applyEligibility();
        // During the notice the policy is not consulted yet.
        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);

        vm.warp(readyAt);
        vm.expectEmit(address(vault));
        emit GRETVault.EligibilityChanged(address(0), address(policy));
        vm.prank(CAROL);
        vault.applyEligibility();
        assertEq(address(vault.eligibility()), address(policy));
        (next,) = vault.eligibilityProposal();
        assertEq(next, address(0));
    }

    function test_onlyGovernanceProposesCancelsAndRemoves() public {
        policy = new MockEligibility();
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotGovernance.selector, ALICE));
        vault.proposeEligibility(address(policy));
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotGovernance.selector, ALICE));
        vault.cancelEligibilityProposal();
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotGovernance.selector, ALICE));
        vault.removeEligibility();
        vm.stopPrank();

        vm.startPrank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.NotAContract.selector, BOB));
        vault.proposeEligibility(BOB);
        vm.expectRevert(abi.encodeWithSelector(GRETVault.InvalidContract.selector, address(vault)));
        vault.proposeEligibility(address(vault));
        vault.proposeEligibility(address(policy));
        vault.cancelEligibilityProposal();
        vm.expectRevert(GRETVault.NoPendingProposal.selector);
        vault.cancelEligibilityProposal();
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(GRETVault.NoPendingProposal.selector);
        vault.applyEligibility();
    }

    /// The contract sees who pays or burns and who receives, and may refuse either.
    function test_eligibilityDecidesMintAndRedemption() public {
        _appointPolicy();
        policy.setListed(ALICE, true);
        policy.setListed(BOB, true);

        _expectNotEligible(BOB, CAROL);
        vm.prank(BOB);
        vault.mint(SHARE, CAROL, _pair(2e18, 5e18), SHARE, 0);
        vm.prank(BOB);
        vault.mint(SHARE, BOB, _pair(2e18, 5e18), SHARE, 0);

        _expectNotEligible(BOB, CAROL);
        vm.prank(BOB);
        vault.redeem(SHARE, CAROL, _pair(0, 0), 0);
        vm.prank(BOB);
        vault.transfer(CAROL, SHARE);
        _expectNotEligible(CAROL, CAROL);
        vm.prank(CAROL);
        vault.redeemSkipping(SHARE, CAROL, _pair(0, 0), new address[](0), 0);

        policy.setListed(CAROL, true);
        vm.prank(CAROL);
        vault.redeem(SHARE, CAROL, _pair(0, 0), 0);
        assertEq(healthy.balanceOf(CAROL), 2e18);
    }

    /// Only an explicit true passes: a revert, a short or non-boolean answer, or one that runs out
    /// of gas refuses, so a caller cannot starve the call into approval.
    function test_brokenAnswersRefuse() public {
        _appointPolicy();
        policy.setListed(ALICE, true);
        MockEligibility.Answer[4] memory broken = [
            MockEligibility.Answer.Revert,
            MockEligibility.Answer.Short,
            MockEligibility.Answer.NotABool,
            MockEligibility.Answer.BurnGas
        ];
        for (uint256 i; i < broken.length; ++i) {
            policy.setAnswer(broken[i]);
            _expectNotEligible(ALICE, ALICE);
            vm.prank(ALICE);
            vault.mint{gas: 2_000_000}(SHARE, ALICE, _pair(2e18, 5e18), SHARE, 0);
            _expectNotEligible(ALICE, ALICE);
            vm.prank(ALICE);
            vault.redeem{gas: 2_000_000}(SHARE, ALICE, _pair(0, 0), 0);
        }
    }

    /// A broken or hostile contract can be removed at once; a pending proposal stays.
    function test_removalIsImmediate() public {
        _appointPolicy();
        policy.setAnswer(MockEligibility.Answer.Revert);
        MockEligibility replacement = new MockEligibility();
        vm.startPrank(GOVERNANCE);
        vault.proposeEligibility(address(replacement));
        vm.expectEmit(address(vault));
        emit GRETVault.EligibilityChanged(address(policy), address(0));
        vault.removeEligibility();
        vm.recordLogs();
        vault.removeEligibility();
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(address(vault.eligibility()), address(0));
        (address next,) = vault.eligibilityProposal();
        assertEq(next, address(replacement));

        vm.prank(ALICE);
        vault.redeem(SHARE, ALICE, _pair(0, 0), 0);
    }

    /// Transfers and liquidation never ask the eligibility contract.
    function test_transfersAndLiquidationIgnoreEligibility() public {
        _appointPolicy();
        policy.setAnswer(MockEligibility.Answer.Revert);
        vm.prank(ALICE);
        vault.transfer(CAROL, SHARE / 2);

        vm.prank(GOVERNANCE);
        vault.activateLiquidation();
        vm.startPrank(CAROL);
        vault.convertToClaims(SHARE / 2);
        assertEq(vault.claim(0, CAROL, 0), 1e18);
        vm.stopPrank();
    }
}
