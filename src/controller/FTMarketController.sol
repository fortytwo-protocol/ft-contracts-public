// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@ft/src/controller/mixins/MarketFactory.sol";
import "@ft/src/controller/mixins/Registry.sol";
import "@ft/src/controller/mixins/Governance.sol";
import "@ft/lib/Question.sol";
import "@ft/lib/Event.sol";
import "@ft/src/interfaces/IFTMarket.sol";
import "@ft/src/interfaces/IRegistry.sol";

contract FTMarketController is MarketFactory, Registry, Governance, AccessControlDefaultAdminRules, ReentrancyGuard {
    using Question for QuestionState;

    bytes32 private constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 private constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 private constant QUESTION_RESOLVER_ROLE = keccak256("QUESTION_RESOLVER_ROLE");
    bytes32 private constant QUESTION_FINALISER_ROLE = keccak256("QUESTION_FINALISER_ROLE");
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    constructor(address _treasury)
        MarketFactory(address(this))
        Governance(_treasury)
        AccessControlDefaultAdminRules(3 days, msg.sender)
    {
        _grantRole(PAUSER_ROLE, msg.sender);
    }

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
        )
    {
        (_treasury, _feeRate) = _getGovernance(market);

        bytes32 questionId = IFTMarket(market).questionId();
        (QuestionState storage question,) = _getState(questionId);
        _numOutcomes = question.getNumOutcomes();
        _answer = question.answer;
        _isFinalised = question.isFinalised();
        _timestampEnd = question.timestampEnd;
    }

    function setProtocolFeeRate(address market, uint80 feeRate) external nonReentrant onlyRole(MARKET_CREATOR_ROLE) {
        _setProtocolFeeRate(market, feeRate);
    }

    function setTreasury(address treasuryNew) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasuryNew == address(0) || this.isMarket(treasuryNew)) revert Errors.RegistryInvalidTreasuryAddress();
        _setTreasury(treasuryNew);
    }

    function deployMarketAndSeedLiquidity(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint256 otSeed,
        uint128 timestampStart,
        uint80 feeRate
    ) external nonReentrant onlyRole(MARKET_CREATOR_ROLE) returns (address) {
        (, QuestionParams memory question) = getQuestion(questionId);
        if (Question.isEmptyQuestion(question)) revert Errors.RegistryNotRegistered();

        address market = _deployMarket(collateral, parentTokenId, questionId, curve, timestampStart);
        _seedLiquidity(market, collateral, parentTokenId, questionId, curve, otSeed);
        _setProtocolFeeRate(market, feeRate); // NOTE: set fee after seeding, seed incurs no fees.

        return market;
    }

    function createQuestion(QuestionParams calldata params, uint128 timestampEnd, string[] calldata names)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
        returns (bytes32)
    {
        bytes32 questionId = _createQuestion(params, timestampEnd, names);
        return questionId;
    }

    function extendOutcomeEnd(bytes32 questionId, uint128 timestampEnd)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        _extendEnd(questionId, timestampEnd);
    }

    function addOutcomes(bytes32 questionId, string[] calldata names)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        // note: added outcomes do not come with seeded liquidity as liquidity is seeded on market creation
        _addOutcome(questionId, names);
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) external nonReentrant onlyRole(QUESTION_RESOLVER_ROLE) {
        _resolveOutcome(questionId, answer);
    }

    function unresolveOutcome(bytes32 questionId) external nonReentrant onlyRole(QUESTION_RESOLVER_ROLE) {
        _unresolveOutcome(questionId);
    }

    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge)
        external
        nonReentrant
        onlyRole(QUESTION_FINALISER_ROLE)
    {
        _finaliseOutcome(questionId, answerChallenge);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
