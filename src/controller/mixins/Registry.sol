// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@ft/src/interfaces/IRegistry.sol";
import "@ft/lib/Event.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/Question.sol";

// number of outcomes = number of binary bits
// outcome > 1 and < 2^number of outcomes, where the outcome number is translated
// to binary
// eg, num of outcomes = 3, outcome of 4 = 0b100 (binary), this means the third option is the correct outcome

abstract contract Registry is IRegistry, HasFTEvents {
    using Question for QuestionParams;
    using Question for QuestionState;

    address private constant NULL_POINTER_ADDRESS_STORED = address(0);

    mapping(bytes32 => QuestionState) private questionIdToQuestionState;
    mapping(bytes32 => OutcomeNameDeduplicator) private outcomeNameDeduplicators;

    function _createQuestion(QuestionParams calldata params, uint128 timestampEnd, string[] calldata names)
        internal
        returns (bytes32 questionId)
    {
        questionId = params.getId();
        (QuestionState storage question, OutcomeNameDeduplicator storage dedup) = _getState(questionId);

        question.register(dedup, params, timestampEnd, names);

        emit CreateNewQuestion(questionId, params.title, question.ptr);
        emit ExtendEnd(questionId, Question.EMPTY_TIMESTAMP_END, timestampEnd);
        uint256 len = names.length;
        for (uint256 i = 0; i < len; ++i) {
            emit AddOutcome(questionId, i, names[i]);
        }
    }

    function _addOutcome(bytes32 questionId, string[] calldata names) internal {
        (QuestionState storage question, OutcomeNameDeduplicator storage dedup) = _getState(questionId);

        uint256 numOutcomesPrev = question.getNumOutcomes();
        question.addOutcomes(dedup, names);
        uint256 numOutcomesNew = question.getNumOutcomes();

        // numOutcomes start from 1, index start from 0
        for (uint256 i = numOutcomesPrev; i < numOutcomesNew; ++i) {
            emit AddOutcome(questionId, i, question.names[i]);
        }
    }

    function _extendEnd(bytes32 questionId, uint128 timestampEnd) internal {
        (QuestionState storage question,) = _getState(questionId);

        uint128 timestampPrev = question.timestampEnd;
        question.extendEnd(timestampEnd);

        emit ExtendEnd(questionId, timestampPrev, timestampEnd);
    }

    function _resolveOutcome(bytes32 questionId, uint256 answer) internal {
        (QuestionState storage question,) = _getState(questionId);

        uint256 answerPrev = question.answer;
        question.resolve(answer);

        emit Resolve(questionId, answerPrev, question.answer);
    }

    function _unresolveOutcome(bytes32 questionId) internal {
        (QuestionState storage question,) = _getState(questionId);
        uint256 answerPrev = question.answer;
        question.unresolve();

        emit Resolve(questionId, answerPrev, question.answer);
    }

    function _finaliseOutcome(bytes32 questionId, uint256 answerChallenge) internal {
        (QuestionState storage question,) = _getState(questionId);
        question.finalise(answerChallenge);

        emit Finalise(questionId, answerChallenge);
    }

    // read stuff
    function getQuestionId(QuestionParams memory question) external pure returns (bytes32 questionId) {
        return question.getId();
    }

    function getQuestion(bytes32 questionId)
        public
        view
        returns (QuestionState memory question, QuestionParams memory params)
    {
        (QuestionState storage state,) = _getState(questionId);

        params = state.getQuestionParams();
        question = state;
    }

    function isFinalised(bytes32 questionId) external view returns (bool) {
        (QuestionState storage question,) = _getState(questionId);
        return question.isFinalised();
    }

    function getOutcomeAnswer(bytes32 questionId) external view returns (uint256) {
        (QuestionState storage question,) = _getState(questionId);
        return question.answer;
    }

    function getOutcomeEnd(bytes32 questionId) external view returns (uint128) {
        (QuestionState storage question,) = _getState(questionId);
        return question.timestampEnd;
    }

    function getNumOutcomes(bytes32 questionId) external view returns (uint256 numOutcomes) {
        (QuestionState storage question,) = _getState(questionId);
        return question.names.length;
    }

    function getOutcomeNames(bytes32 questionId) external view returns (string[] memory) {
        (QuestionState storage question,) = _getState(questionId);
        return question.names;
    }

    function _getState(bytes32 questionId)
        internal
        view
        returns (QuestionState storage question, OutcomeNameDeduplicator storage dedup)
    {
        question = questionIdToQuestionState[questionId];
        dedup = outcomeNameDeduplicators[questionId];
    }
}
