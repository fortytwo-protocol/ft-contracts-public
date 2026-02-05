// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {QuestionParams, QuestionState} from "@ft/lib/Question.sol";

interface IRegistry {
    function getQuestionId(QuestionParams memory question) external view returns (bytes32 questionId);

    function getQuestion(bytes32 questionId)
        external
        view
        returns (QuestionState memory question, QuestionParams memory params);

    function isFinalised(bytes32 questionId) external view returns (bool finalised);

    function getOutcomeAnswer(bytes32 questionId) external view returns (uint256 answer);

    function getOutcomeEnd(bytes32 questionId) external view returns (uint128 timestampEnd);

    function getNumOutcomes(bytes32 questionId) external view returns (uint256 numOutcomes);

    function getOutcomeNames(bytes32 questionId) external view returns (string[] memory names);

    function getConfig(address market)
        external
        view
        returns (
            address _treasury,
            uint80 _feeRate,
            uint256 _numOutcomes,
            uint128 _timestampEnd,
            uint256 _answer,
            bool _isFinalised
        );

    function isPaused() external view returns (bool);
}
