// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {HasFTEvents} from "@ft/lib/Event.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {QuestionV2} from "@ft/lib/QuestionV2.sol";
import {
    ControllerStorage,
    QuestionStateV2,
    AncillaryDataUpdate,
    RegistryStorage,
    OutcomeNameDeduplicator,
    QuestionParams
} from "@ft/src/controllerv2/ControllerStorage.sol";

library Registry {
    uint256 private constant MAX_UPDATE_LENGTH = 30000;

    using QuestionV2 for QuestionStateV2;

    function createQuestion(QuestionParams calldata params, address oracle, address creator)
        public
        returns (bytes32 questionId)
    {
        if (oracle == address(0)) revert Errors.RegistryInvalidOracleAddress();
        questionId = QuestionV2.getId(creator, oracle, params.title, params.ancillaryData);

        _registerQuestion(questionId, params, oracle, creator);
        _emitQuestionCreated(questionId, params, oracle, creator);
        postUpdate(questionId, params.ancillaryData);
    }

    function _registerQuestion(bytes32 questionId, QuestionParams calldata params, address oracle, address creator)
        private
    {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage state = reg.questions[questionId];

        state.register(
            reg.outcomeDeduplicators[questionId],
            creator,
            oracle,
            params.timestampEnd,
            params.title,
            params.imageUri,
            params.outcomeNames,
            params.outcomeImageUris
        );
    }

    function _emitQuestionCreated(bytes32 questionId, QuestionParams calldata params, address oracle, address creator)
        private
    {
        emit HasFTEvents.CreateNewQuestionV2(
            questionId,
            oracle,
            creator,
            params.title,
            params.imageUri,
            params.timestampEnd,
            params.outcomeNames,
            params.outcomeImageUris,
            params.ancillaryData
        );
        emit HasFTEvents.ModifyEnd(questionId, 0, params.timestampEnd);

        emit HasFTEvents.QuestionImageUpdated(questionId, params.imageUri);
        uint256 len = params.outcomeNames.length;
        for (uint256 i = 0; i < len; ++i) {
            emit HasFTEvents.AddOutcome(questionId, i, params.outcomeNames[i]);
            emit HasFTEvents.OutcomeImageUpdated(questionId, i, params.outcomeImageUris[i]);
        }
    }

    function addOutcomes(bytes32 questionId, string[] calldata outcomeNames, string[] calldata outcomeImageUris)
        public
    {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];
        OutcomeNameDeduplicator storage dedup = reg.outcomeDeduplicators[questionId];

        uint256 numOutcomesPrev = question.getNumOutcomes();
        question.addOutcomes(dedup, outcomeNames, outcomeImageUris);
        uint256 numOutcomesNew = question.getNumOutcomes();

        // numOutcomes start from 1, index start from 0
        for (uint256 i = numOutcomesPrev; i < numOutcomesNew; ++i) {
            emit HasFTEvents.AddOutcome(questionId, i, question.outcomeNames[i]);
            emit HasFTEvents.OutcomeImageUpdated(questionId, i, question.outcomeImageUris[i]);
        }
    }

    function modifyEnd(bytes32 questionId, uint96 timestampEndNew) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];
        if (!question.isRegistered()) revert Errors.RegistryQuestionNotFound();

        uint96 prev = question.timestampEnd;
        question.modifyEnd(timestampEndNew);

        emit HasFTEvents.ModifyEnd(questionId, prev, timestampEndNew);
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        uint256 answerPrev = question.answer;
        question.resolve(answer);

        emit HasFTEvents.Resolve(questionId, answerPrev, question.answer);
    }

    function unresolveOutcome(bytes32 questionId) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        uint256 answerPrev = question.answer;
        question.unresolve();

        emit HasFTEvents.Resolve(questionId, answerPrev, question.answer);
    }

    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];
        if (!question.isRegistered()) revert Errors.RegistryQuestionNotFound();

        question.finalise(answerChallenge);

        emit HasFTEvents.Finalise(questionId, answerChallenge);
    }

    function flag(bytes32 questionId) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        question.flag();

        emit HasFTEvents.QuestionFlagged(questionId, question.timestampFlagExpiry);
    }

    function unflag(bytes32 questionId) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        question.unflag();

        emit HasFTEvents.QuestionUnflagged(questionId);
    }

    function finaliseManually(bytes32 questionId, uint256 answerOverride) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        uint256 answerPrev = question.answer;
        question.manuallyFinalise(answerOverride);

        // treat manual finalise as a re-resolution even if the answer is the same
        emit HasFTEvents.Resolve(questionId, answerPrev, answerOverride);
        emit HasFTEvents.Finalise(questionId, answerOverride);
        emit HasFTEvents.ManuallyFinalise(questionId, answerOverride);
    }

    function setImageUri(bytes32 questionId, string calldata imageUri) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];
        if (!question.isRegistered()) revert Errors.RegistryQuestionNotFound();

        question.imageUri = imageUri;

        emit HasFTEvents.QuestionImageUpdated(questionId, imageUri);
    }

    function setOutcomeImageUri(bytes32 questionId, uint256 indexOutcome, string calldata imageUri) public {
        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];
        if (!question.isRegistered()) revert Errors.RegistryQuestionNotFound();
        if (indexOutcome >= question.outcomeImageUris.length) revert Errors.RegistryInvalidNumOutcomes();

        question.outcomeImageUris[indexOutcome] = imageUri;
        emit HasFTEvents.OutcomeImageUpdated(questionId, indexOutcome, imageUri);
    }

    function postUpdate(bytes32 questionId, bytes memory update) public {
        if (update.length > MAX_UPDATE_LENGTH) revert Errors.RegistryExceedMaxAncillaryDataUpdateLength();

        RegistryStorage storage reg = ControllerStorage.registry();
        if (!reg.questions[questionId].isRegistered()) revert Errors.RegistryQuestionNotFound();

        bytes32 id = QuestionV2.getUpdateId(questionId, msg.sender);
        reg.updates[id].push(AncillaryDataUpdate({timestamp: block.timestamp, update: update}));

        emit HasFTEvents.AncillaryDataUpdated(questionId, msg.sender, update);
    }

    function getUpdates(bytes32 questionId, address owner) public view returns (AncillaryDataUpdate[] memory) {
        RegistryStorage storage reg = ControllerStorage.registry();
        bytes32 id = QuestionV2.getUpdateId(questionId, owner);
        return reg.updates[id];
    }

    function getLatestUpdate(bytes32 questionId, address owner) public view returns (AncillaryDataUpdate memory) {
        RegistryStorage storage reg = ControllerStorage.registry();
        bytes32 id = QuestionV2.getUpdateId(questionId, owner);
        AncillaryDataUpdate[] storage updatesOwner = reg.updates[id];
        if (updatesOwner.length == 0) return AncillaryDataUpdate({timestamp: 0, update: ""});
        return updatesOwner[updatesOwner.length - 1];
    }

    function getUpdatesPaginated(bytes32 questionId, address owner, uint256 offset, uint256 limit)
        public
        view
        returns (AncillaryDataUpdate[] memory page)
    {
        RegistryStorage storage reg = ControllerStorage.registry();
        bytes32 id = QuestionV2.getUpdateId(questionId, owner);

        AncillaryDataUpdate[] storage updatesOwner = reg.updates[id];
        uint256 total = updatesOwner.length;
        if (offset >= total) return new AncillaryDataUpdate[](0);

        uint256 from = offset;
        uint256 to = from + limit;
        if (to > total) to = total;
        uint256 len = to - from;

        page = new AncillaryDataUpdate[](len);
        for (uint256 i = 0; i < len; ++i) {
            page[i] = updatesOwner[from + i];
        }
    }
}
