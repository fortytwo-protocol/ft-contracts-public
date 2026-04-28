// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IFTControllerV2} from "@ft/src/interfaces/IFTControllerV2.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";

import {QuestionV2} from "@ft/lib/QuestionV2.sol";
import {Market, MarketDeployParams} from "@ft/lib/Market.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {FTMath} from "@ft/lib/FTMath.sol";

import {
    ControllerStorage,
    QuestionStateV2,
    AncillaryDataUpdate,
    GovernanceStorage,
    RegistryStorage,
    CollateralConfig,
    QuestionParams,
    MarketParams
} from "@ft/src/controllerv2/ControllerStorage.sol";
import {Governance} from "@ft/src/controllerv2/Governance.sol";
import {Registry} from "@ft/src/controllerv2/Registry.sol";
import {MarketFactory} from "@ft/src/controllerv2/MarketFactory.sol";

contract FTControllerV2 is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardTransient,
    Governance,
    MarketFactory,
    IFTControllerV2,
    IRegistry
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using QuestionV2 for QuestionStateV2;
    using FTMath for uint256;

    bytes32 private constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 private constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    bytes private constant EMPTY_BYTES = "";

    modifier whenUnpaused() {
        if (_isPaused()) revert Errors.RegistryPaused();
        _;
    }

    modifier onlyCreator(bytes32 questionId) {
        _onlyCreator(questionId, msg.sender);
        _;
    }

    modifier onlyOracle(bytes32 questionId) {
        _onlyOracle(questionId, msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address treasury_, uint80 feeRateDefault_, uint48 adminTransferDelay_)
        external
        initializer
    {
        __AccessControlDefaultAdminRules_init(adminTransferDelay_, admin_);
        __Governance_init(treasury_, feeRateDefault_);
    }

    function deployMarket(
        QuestionParams calldata paramsQuestion,
        MarketParams calldata paramsMarket,
        address oracle,
        uint256 otSeed
    ) external whenUnpaused nonReentrant returns (bytes32 questionId, address market) {
        GovernanceStorage storage gov = ControllerStorage.governance();

        if (otSeed == 0) revert Errors.FactoryInvalidSeedAmount();
        if (paramsMarket.curve == address(0)) revert Errors.FactoryInvalidCurve();
        if (!gov.whitelistedCurves[paramsMarket.curve]) revert Errors.FactoryCurveNotAllowed();
        if (paramsMarket.collateral == address(0)) revert Errors.FactoryNativeTokenNotAllowed();
        if (paramsMarket.parentTokenId == NULL_PARENT_ID) {
            if (!gov.whitelistedCollaterals[paramsMarket.collateral].isWhitelisted) {
                revert Errors.RegistryCollateralNotWhitelisted();
            }
        }

        uint256 numOutcomes;
        (questionId, numOutcomes) = _ensureQuestionCreated(paramsQuestion, oracle);

        market = _deployMarket(
            paramsMarket.collateral,
            paramsMarket.parentTokenId,
            questionId,
            paramsMarket.curve,
            paramsMarket.timestampStart
        );
        emit CreateNewMarket(
            market,
            paramsMarket.collateral,
            paramsMarket.parentTokenId,
            questionId,
            paramsMarket.curve,
            IFTMarket(market).timestampStart()
        );

        _seed(market, paramsMarket, numOutcomes, otSeed);
    }

    function seedLiquidity(address market, uint256[] calldata tokenIds, uint256[] calldata otAmounts)
        external
        whenUnpaused
        nonReentrant
    {
        RegistryStorage storage reg = ControllerStorage.registry();
        if (!reg.markets.contains(market)) revert Errors.RegistryMarketNotFound();

        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
        _onlyCreator(params.questionId, msg.sender);
        QuestionStateV2 storage question = reg.questions[params.questionId];
        if (question.answer != 0 || question.isFinalised()) revert Errors.MarketResolved();

        _seedLiquidity(market, params.collateral, params.parentTokenId, params.curve, tokenIds, otAmounts);
    }

    function postUpdate(bytes32 questionId, bytes calldata update) external {
        Registry.postUpdate(questionId, update);
    }

    function addOutcomes(bytes32 questionId, string[] calldata names, string[] calldata imageUris)
        external
        nonReentrant
        onlyCreator(questionId)
    {
        Registry.addOutcomes(questionId, names, imageUris);
    }

    function modifyTimestampEnd(bytes32 questionId, uint128 timestampEndNew)
        external
        nonReentrant
        onlyCreator(questionId)
    {
        Registry.modifyEnd(questionId, FTMath.toUint96(uint256(timestampEndNew)));
    }

    function setImageUri(bytes32 questionId, string calldata imageUri) external nonReentrant onlyCreator(questionId) {
        Registry.setImageUri(questionId, imageUri);
    }

    function setOutcomeImageUri(bytes32 questionId, uint256 indexOutcome, string calldata imageUri)
        external
        nonReentrant
        onlyCreator(questionId)
    {
        Registry.setOutcomeImageUri(questionId, indexOutcome, imageUri);
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) external nonReentrant onlyOracle(questionId) {
        Registry.resolveOutcome(questionId, answer);
    }

    function unresolveOutcome(bytes32 questionId) external nonReentrant onlyOracle(questionId) {
        Registry.unresolveOutcome(questionId);
    }

    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge) external nonReentrant onlyOracle(questionId) {
        Registry.finaliseOutcome(questionId, answerChallenge);
    }

    function flag(bytes32 questionId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Registry.flag(questionId);
    }

    function unflag(bytes32 questionId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Registry.unflag(questionId);
    }

    function finaliseManually(bytes32 questionId, uint256 answer) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Registry.finaliseManually(questionId, answer);
    }

    function setWhitelistedCurve(address curve, bool whitelist) external onlyRole(OPERATOR_ROLE) {
        _setWhitelistedCurve(curve, whitelist);
    }

    function setFeeRateOverride(address market, uint80 feeRate, bool isOverride) external onlyRole(OPERATOR_ROLE) {
        _setFeeRateOverride(market, feeRate, isOverride);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTreasury(treasury_);
    }

    function setFeeRateDefault(uint80 feeRateNew) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeeRateDefault(feeRateNew);
    }

    function setWhitelistedCollateral(address collateral, bool whitelist, uint256 collateralSeedMin)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setWhitelistedCollateral(collateral, whitelist, collateralSeedMin);
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function isPaused() external view returns (bool) {
        return _isPaused();
    }

    function isMarket(address market) external view returns (bool) {
        return ControllerStorage.registry().markets.contains(market);
    }

    function getDefaultFeeRate() external view returns (uint80) {
        return ControllerStorage.governance().feeRateDefault;
    }

    function getFeeRate(address market) external view returns (uint80) {
        return _getFeeRate(market);
    }

    function getNumOutcomes(bytes32 questionId) external view returns (uint256) {
        return ControllerStorage.registry().questions[questionId].getNumOutcomes();
    }

    function getOutcomeEnd(bytes32 questionId) external view returns (uint128) {
        return ControllerStorage.registry().questions[questionId].timestampEnd;
    }

    function isFinalised(bytes32 questionId) external view returns (bool) {
        return ControllerStorage.registry().questions[questionId].isFinalised();
    }

    function getOutcomeAnswer(bytes32 questionId) external view returns (uint256) {
        return ControllerStorage.registry().questions[questionId].answer;
    }

    function getOutcomeNames(bytes32 questionId) external view returns (string[] memory) {
        return ControllerStorage.registry().questions[questionId].outcomeNames;
    }

    /// @dev forked from uma-ctf-adaptor but using ControllerStorage slots
    function getAncillaryUpdates(bytes32 questionId, address owner)
        external
        view
        returns (AncillaryDataUpdate[] memory)
    {
        return Registry.getUpdates(questionId, owner);
    }

    /// @dev forked from uma-ctf-adaptor but using ControllerStorage slots
    function getLatestAncillaryUpdate(bytes32 questionId, address owner)
        external
        view
        returns (AncillaryDataUpdate memory)
    {
        return Registry.getLatestUpdate(questionId, owner);
    }

    function getAncillaryUpdatesPaginated(bytes32 questionId, address owner, uint256 offset, uint256 limit)
        external
        view
        returns (AncillaryDataUpdate[] memory)
    {
        return Registry.getUpdatesPaginated(questionId, owner, offset, limit);
    }

    function getConfig(address market)
        external
        view
        returns (
            address treasuryOut,
            uint80 feeRate,
            uint256 numOutcomes,
            uint128 timestampEnd,
            uint256 answer,
            bool isFinalised_
        )
    {
        GovernanceStorage storage gov = ControllerStorage.governance();
        RegistryStorage storage reg = ControllerStorage.registry();

        treasuryOut = gov.treasury;
        feeRate = _getFeeRate(market);

        bytes32 questionId = IFTMarket(market).questionId();
        QuestionStateV2 storage question = reg.questions[questionId];
        numOutcomes = question.getNumOutcomes();
        timestampEnd = question.timestampEnd;
        answer = question.answer;
        isFinalised_ = question.isFinalised();
    }

    function predictMarketAddress(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint128 timestampStart
    ) external view returns (address) {
        return _computeCounterfactual(
            MarketDeployParams({
                collateral: collateral,
                parentTokenId: parentTokenId,
                questionId: questionId,
                curve: curve,
                timestampStart: timestampStart
            })
        );
    }

    function _onlyCreator(bytes32 questionId, address creator) internal view {
        RegistryStorage storage $ = ControllerStorage.registry();
        if (!$.questions[questionId].isRegistered()) revert Errors.RegistryQuestionNotFound();
        if ($.questions[questionId].creator != creator) revert Errors.RegistryOnlyCreator();
    }

    function _onlyOracle(bytes32 questionId, address oracle) internal view {
        RegistryStorage storage $ = ControllerStorage.registry();
        if (!$.questions[questionId].isRegistered()) revert Errors.RegistryQuestionNotFound();
        if ($.questions[questionId].oracle != oracle) revert Errors.RegistryOnlyOracle();
    }

    function _isPaused() internal view returns (bool) {
        GovernanceStorage storage $ = ControllerStorage.governance();
        return $.paused;
    }

    function _ensureQuestionCreated(QuestionParams calldata paramsQuestion, address oracle)
        private
        returns (bytes32 questionId, uint256 numOutcomes)
    {
        questionId = QuestionV2.getId(msg.sender, oracle, paramsQuestion.title, paramsQuestion.ancillaryData);

        RegistryStorage storage reg = ControllerStorage.registry();
        QuestionStateV2 storage question = reg.questions[questionId];

        if (!question.isRegistered()) {
            Registry.createQuestion(paramsQuestion, oracle, msg.sender);

            numOutcomes = paramsQuestion.outcomeNames.length;
        } else {
            // note: questionId guarantees msg.sender == creator
            numOutcomes = question.getNumOutcomes();
        }
    }

    function _seed(address market, MarketParams calldata paramsMarket, uint256 numOutcomes, uint256 otSeed) private {
        uint256[] memory tokenIds = new uint256[](numOutcomes);
        uint256[] memory otAmounts = new uint256[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            tokenIds[i] = Market.toTokenId(i);
            otAmounts[i] = otSeed;
        }

        uint256 collateralTotal = _seedLiquidity(
            market, paramsMarket.collateral, paramsMarket.parentTokenId, paramsMarket.curve, tokenIds, otAmounts
        );

        if (paramsMarket.parentTokenId == NULL_PARENT_ID) {
            GovernanceStorage storage gov = ControllerStorage.governance();
            if (collateralTotal < gov.whitelistedCollaterals[paramsMarket.collateral].collateralSeedMin) {
                revert Errors.RegistrySeedBelowMinimum();
            }
        }

        // note: unable to enforce collateral value for nested markets (marginal price is volatile)
    }
}
