// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@solady/utils/SSTORE2.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/FTMath.sol";

// immutable question title & description stored onchain for public reference
struct QuestionParams {
    string title;
    string description;
}

struct QuestionState {
    // immutable
    address ptr;
    // mutable
    uint256 answer;
    uint128 timestampEnd;
    uint128 timestampFinalise;
    string[] names;
}

struct OutcomeNameDeduplicator {
    mapping(string => bool) dedup;
}

library Question {
    using Question for QuestionParams;
    using Question for QuestionState;
    using FTMath for uint256;

    uint256 private constant MAX_TITLE_LENGTH = 1000;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 30000;
    uint256 private constant MAX_NAME_LENGTH = 50;
    uint256 private constant MAX_NUM_OUTCOMES = 255; // outcome answer is represented as a binary uint256, thus, only 255 possible outcomes are supported

    string private constant EMPTY_TITLE = "";
    string private constant EMPTY_DESCRIPTION = "";
    uint256 private constant EMPTY_ANSWER = 0;
    uint128 private constant EMPTY_TIMESTAMP_FINALISE = 0;
    uint128 public constant EMPTY_TIMESTAMP_END = 0;
    address private constant NULL_POINTER_ADDRESS_STORED = address(0);

    /* QUESTION PARAMS RELATED */
    function store(QuestionParams calldata self) internal returns (address ptr) {
        if (bytes(self.title).length == 0) revert Errors.RegistryEmptyTitle();
        if (bytes(self.title).length > MAX_TITLE_LENGTH) revert Errors.RegistryExceedMaxTitleLength();
        if (bytes(self.description).length > MAX_DESCRIPTION_LENGTH) {
            revert Errors.RegistryExceedMaxDescriptionLength();
        }

        bytes memory data = abi.encode(self.title, self.description);
        ptr = SSTORE2.write(data);
    }

    function getId(QuestionParams memory self) internal pure returns (bytes32 questionId) {
        return keccak256(abi.encode(self.title, self.description));
    }

    function isEmptyQuestion(QuestionParams memory question) internal pure returns (bool) {
        return bytes(question.title).length == 0;
    }

    function emptyQuestion() internal pure returns (QuestionParams memory) {
        return QuestionParams({title: EMPTY_TITLE, description: EMPTY_DESCRIPTION});
    }

    /* QUESTION STATE RELATED */
    function register(
        QuestionState storage self,
        OutcomeNameDeduplicator storage dedup,
        QuestionParams calldata params,
        uint128 timestampEnd,
        string[] calldata outcomeNames
    ) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        uint256 len = outcomeNames.length;
        if (len <= 1) revert Errors.RegistryInsufficientOutcomesGiven();
        if (len > MAX_NUM_OUTCOMES) revert Errors.RegistryExceedMaxNames();
        if (self.isRegistered()) revert Errors.RegistryAlreadyRegistered();
        for (uint256 i = 0; i < len; ++i) {
            string memory name = outcomeNames[i];
            uint256 lenName = bytes(name).length;
            if (lenName == 0) revert Errors.RegistryEmptyName();
            if (lenName > MAX_NAME_LENGTH) revert Errors.RegistryExceedMaxNameLength();
            if (dedup.dedup[name]) revert Errors.RegistryDuplicateOutcome();

            dedup.dedup[name] = true; // note: storage write here
        }

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        address ptr = params.store();
        self.init(ptr, timestampEnd, outcomeNames);
    }

    function init(QuestionState storage self, address ptr, uint128 timestampEnd, string[] memory names) internal {
        if (ptr == NULL_POINTER_ADDRESS_STORED) revert Errors.RegistryInvalidAddressPtr();
        if (timestampEnd < block.timestamp) revert Errors.RegistryEndTimestampHasPassed();

        self.ptr = ptr;
        self.answer = EMPTY_ANSWER;
        self.timestampEnd = timestampEnd;
        self.timestampFinalise = EMPTY_TIMESTAMP_FINALISE;
        self.names = names;
    }

    function addOutcomes(
        QuestionState storage self,
        OutcomeNameDeduplicator storage dedup,
        string[] calldata outcomeNamesToAdd
    ) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot add when finalised
        // can add when resolved (hail mary measure to recover protocol funds if needed)
        uint256 lenOutcomesCurrent = self.names.length;
        uint256 lenOutcomesAdd = outcomeNamesToAdd.length;
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (lenOutcomesAdd == 0) revert Errors.RegistryInsufficientOutcomesGiven();
        if (lenOutcomesCurrent + lenOutcomesAdd > MAX_NUM_OUTCOMES) revert Errors.RegistryExceedMaxNames();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        for (uint256 i = 0; i < lenOutcomesAdd; ++i) {
            string memory name = outcomeNamesToAdd[i];
            uint256 lenName = bytes(name).length;
            if (lenName == 0) revert Errors.RegistryEmptyName();
            if (lenName > MAX_NAME_LENGTH) revert Errors.RegistryExceedMaxNameLength();
            if (dedup.dedup[name]) revert Errors.RegistryDuplicateOutcome();

            dedup.dedup[name] = true;
            self.names.push(name); // ._.
        }
    }

    function extendEnd(QuestionState storage self, uint128 timestampEndNew) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot end when there's no outcome
        // cannot end when it's already finalised
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (self.timestampEnd >= timestampEndNew) revert Errors.RegistryEndTimestampBeforeExisting();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.timestampEnd = timestampEndNew;
    }

    function resolve(QuestionState storage self, uint256 answer) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // can resolve & re-resolve before question end
        // cannot re-resolve the same answer
        // cannot resolve a null-answer (outcomes are exhaustive => at least 1 winner)
        // cannot re-resolve when it's already finalised
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (answer == EMPTY_ANSWER || answer >= 2 ** self.names.length) revert Errors.RegistryInvalidAnswer();
        if (answer == self.answer) revert Errors.RegistrySameAnswer();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.answer = answer;
    }

    function unresolve(QuestionState storage self) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // can unresolve only before finalization & answer exists
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (!self.isResolved()) revert Errors.RegistryNotResolved();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.answer = EMPTY_ANSWER;
    }

    function finalise(QuestionState storage self, uint256 answerChallenge) internal {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        // cannot finalise when there's no outcome
        // cannot finalise when there's no resolution
        if (!self.isRegistered()) revert Errors.RegistryNotRegistered();
        if (self.isFinalised()) revert Errors.RegistryAlreadyFinalised();
        if (!self.isResolved()) revert Errors.RegistryNotResolved();
        if (self.answer != answerChallenge) revert Errors.RegistryAnswerDoesNotMatchCurrent();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.timestampFinalise = block.timestamp.toUint128();
    }

    function getQuestionParams(QuestionState storage self) internal view returns (QuestionParams memory question) {
        if (self.ptr == NULL_POINTER_ADDRESS_STORED) {
            return emptyQuestion();
        }

        bytes memory data = SSTORE2.read(self.ptr);
        (string memory title, string memory description) = abi.decode(data, (string, string));
        return QuestionParams({title: title, description: description});
    }

    function getNumOutcomes(QuestionState storage self) internal view returns (uint256) {
        return self.names.length;
    }

    function isRegistered(QuestionState storage self) internal view returns (bool) {
        return self.ptr != NULL_POINTER_ADDRESS_STORED;
    }

    function isResolved(QuestionState storage self) internal view returns (bool) {
        return self.answer != EMPTY_ANSWER;
    }

    function isFinalised(QuestionState storage self) internal view returns (bool) {
        return self.timestampFinalise != EMPTY_TIMESTAMP_FINALISE;
    }
}
