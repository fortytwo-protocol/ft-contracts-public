// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {Errors} from "@ft/lib/Errors.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {OutcomeNameDeduplicator, QuestionStateV2} from "@ft/src/controllerv2/ControllerStorage.sol";

library QuestionV2 {
    using QuestionV2 for QuestionStateV2;
    using FTMath for uint256;

    uint256 private constant MAX_TITLE_LENGTH = 1000;
    uint256 private constant MAX_NAME_LENGTH = 50;
    uint256 private constant MAX_NUM_OUTCOMES = 255; // outcome answer is represented as a binary uint256, thus, only 255 possible outcomes are supported

    uint256 private constant EMPTY_ANSWER = 0;
    uint96 private constant EMPTY_TIMESTAMP_FINALISE = 0;

    uint256 private constant SAFETY_PERIOD = 1 days;

    function register(
        QuestionStateV2 storage self,
        OutcomeNameDeduplicator storage dedup,
        address creator,
        address oracle,
        uint96 timestampEnd,
        string memory title,
        string memory imageUri,
        string[] memory outcomeNames,
        string[] memory outcomeImageUris
    ) internal {
        uint256 len = outcomeNames.length;
        if (len <= 1) revert Errors.RegistryInsufficientOutcomesGiven();
        if (len > MAX_NUM_OUTCOMES) revert Errors.RegistryExceedMaxNames();
        if (outcomeNames.length != outcomeImageUris.length) revert Errors.RegistryOutcomeImagesMismatch();
        if (self.isRegistered()) revert Errors.RegistryAlreadyRegistered();
        if (timestampEnd < block.timestamp) revert Errors.RegistryEndTimestampHasPassed();
        if (bytes(title).length == 0) revert Errors.RegistryEmptyTitle();
        if (bytes(title).length > MAX_TITLE_LENGTH) revert Errors.RegistryExceedMaxTitleLength();

        for (uint256 i = 0; i < len; ++i) {
            string memory name = outcomeNames[i];
            uint256 lenName = bytes(name).length;
            if (lenName == 0) revert Errors.RegistryEmptyName();
            if (lenName > MAX_NAME_LENGTH) revert Errors.RegistryExceedMaxNameLength();
            if (dedup.dedup[name]) revert Errors.RegistryDuplicateOutcome();
            dedup.dedup[name] = true;
        }

        self.creator = creator;
        self.oracle = oracle;
        self.timestampEnd = timestampEnd;
        self.title = title;
        self.imageUri = imageUri;
        self.outcomeNames = outcomeNames;
        self.outcomeImageUris = outcomeImageUris;
    }

    function addOutcomes(
        QuestionStateV2 storage self,
        OutcomeNameDeduplicator storage dedup,
        string[] calldata outcomeNamesToAdd,
        string[] calldata outcomeImageUrisToAdd
    ) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot add when finalised
        // can add when resolved (hail mary measure to recover protocol funds if needed)
        uint256 lenOutcomesCurrent = self.outcomeNames.length;
        uint256 lenOutcomesAdd = outcomeNamesToAdd.length;
        if (outcomeNamesToAdd.length != outcomeImageUrisToAdd.length) revert Errors.RegistryOutcomeLengthMismatch();
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (self.isFlagged()) revert Errors.RegistryQuestionIsFlagged();
        if (lenOutcomesAdd == 0) revert Errors.RegistryInsufficientOutcomesGiven();
        if (lenOutcomesCurrent + lenOutcomesAdd > MAX_NUM_OUTCOMES) revert Errors.RegistryExceedMaxNames();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        for (uint256 i = 0; i < lenOutcomesAdd; ++i) {
            string memory name = outcomeNamesToAdd[i];
            string memory imageUri = outcomeImageUrisToAdd[i];
            uint256 lenName = bytes(name).length;
            if (lenName == 0) revert Errors.RegistryEmptyName();
            if (lenName > MAX_NAME_LENGTH) revert Errors.RegistryExceedMaxNameLength();
            if (dedup.dedup[name]) revert Errors.RegistryDuplicateOutcome();

            dedup.dedup[name] = true;
            self.outcomeNames.push(name); // ._.
            self.outcomeImageUris.push(imageUri);
        }
    }

    function isRegistered(QuestionStateV2 storage self) internal view returns (bool) {
        return self.creator != address(0);
    }

    function isResolved(QuestionStateV2 storage self) internal view returns (bool) {
        return self.answer != EMPTY_ANSWER;
    }

    function isFlagged(QuestionStateV2 storage self) internal view returns (bool) {
        return self.timestampFlagExpiry != 0;
    }

    function isFinalised(QuestionStateV2 storage self) internal view returns (bool) {
        return self.timestampFinalise != EMPTY_TIMESTAMP_FINALISE;
    }

    function getNumOutcomes(QuestionStateV2 storage self) internal view returns (uint256) {
        return self.outcomeNames.length;
    }

    function getId(address creator, address oracle, string memory title, bytes memory ancillaryData)
        internal
        pure
        returns (bytes32 questionId)
    {
        return keccak256(abi.encode(creator, oracle, title, ancillaryData));
    }

    function getUpdateId(bytes32 questionId, address owner) internal pure returns (bytes32 updateId) {
        return keccak256(abi.encode(questionId, owner));
    }

    function modifyEnd(QuestionStateV2 storage self, uint96 timestampEndNew) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot end when there's no question
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        // to harden the contracts: timestampEnd = max(block.timestamp-1,timestampEnd)
        // note: this still does not remove the issue that start can be > end and curves should be aware of this
        uint96 timestampGuard = (block.timestamp - 1).toUint96(); // whether trading stops before or after timestampEnd, this guarantees it will end
        if (timestampEndNew < timestampGuard) {
            self.timestampEnd = timestampGuard;
        } else {
            self.timestampEnd = timestampEndNew;
        }
    }

    function resolve(QuestionStateV2 storage self, uint256 answer) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // can resolve & re-resolve before question end
        // cannot re-resolve the same answer
        // cannot resolve a null-answer (outcomes are exhaustive => at least 1 winner)
        // cannot re-resolve when it's already finalised
        // if flagged, resolution & finalisation is frozen to allow manual intervention
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (self.isFlagged()) revert Errors.RegistryQuestionIsFlagged();
        if (answer == EMPTY_ANSWER || answer >= 2 ** self.outcomeNames.length) revert Errors.RegistryInvalidAnswer();
        if (answer == self.answer) revert Errors.RegistrySameAnswer();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.answer = answer;
    }

    function unresolve(QuestionStateV2 storage self) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // can unresolve only before finalization & answer exists
        // if flagged, resolution & finalisation is frozen to allow manual intervention
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (!self.isResolved()) revert Errors.RegistryNotResolved();
        if (self.isFlagged()) revert Errors.RegistryQuestionIsFlagged();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.answer = EMPTY_ANSWER;
    }

    function flag(QuestionStateV2 storage self) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFlagged()) revert Errors.RegistryAlreadyFlagged();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.timestampFlagExpiry = (block.timestamp + SAFETY_PERIOD).toUint96();
    }

    function unflag(QuestionStateV2 storage self) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (!self.isFlagged()) revert Errors.RegistryNotFlagged();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.timestampFlagExpiry = 0;
    }

    function finalise(QuestionStateV2 storage self, uint256 answerChallenge) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot finalise when there's no outcome
        // cannot finalise when there's no resolution
        // if flagged, resolution & finalisation is frozen to allow manual intervention
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (!self.isResolved()) revert Errors.RegistryNotResolved();
        if (self.isFlagged()) revert Errors.RegistryQuestionIsFlagged();
        if (self.answer != answerChallenge) revert Errors.RegistryAnswerDoesNotMatchCurrent();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.timestampFinalise = block.timestamp.toUint96();
    }

    function manuallyFinalise(QuestionStateV2 storage self, uint256 answerOverride) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // can finalise different answer
        // can finalise even when there's no resolution
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (!self.isFlagged()) revert Errors.RegistryNotFlagged();
        if (block.timestamp < self.timestampFlagExpiry) revert Errors.RegistryManualFinaliseTooEarly();
        if (answerOverride == EMPTY_ANSWER || answerOverride >= 2 ** self.outcomeNames.length) {
            revert Errors.RegistryInvalidAnswer();
        }

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.answer = answerOverride;
        self.timestampFinalise = block.timestamp.toUint96();
    }
}
