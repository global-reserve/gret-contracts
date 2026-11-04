// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IEligibility} from "../IEligibility.sol";

/// @notice Test-only eligibility contract: approves listed addresses, or answers in a broken way.
contract MockEligibility is IEligibility {
    enum Answer {
        List,
        Revert,
        Short,
        NotABool,
        BurnGas
    }

    Answer public answer;
    mapping(address account => bool) public listed;

    function setAnswer(Answer answer_) external {
        answer = answer_;
    }

    function setListed(address account, bool value) external {
        listed[account] = value;
    }

    function canMint(address caller, address receiver) external view returns (bool) {
        return _answer(caller, receiver);
    }

    function canRedeem(address caller, address receiver) external view returns (bool) {
        return _answer(caller, receiver);
    }

    /// @dev Approves when both addresses are listed; the broken answers ignore the list.
    function _answer(address caller, address receiver) private view returns (bool) {
        Answer mode = answer;
        if (mode == Answer.Revert) revert("refused");
        if (mode == Answer.BurnGas) {
            while (true) {}
        }
        if (mode == Answer.Short) {
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (mode == Answer.NotABool) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return listed[caller] && listed[receiver];
    }
}
