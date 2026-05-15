// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AncillaryData, QuestionData, QuestionOutcome} from "@ft/src/adaptors/libraries/AncillaryData.sol";

import {IFTControllerV2} from "@ft/src/interfaces/IFTControllerV2.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IFTMarketV2} from "@ft/src/interfaces/IFTMarketV2.sol";
import {IOptimisticOracleV2} from "@ft/src/adaptors/interfaces/IOptimisticOracleV2.sol";

import {QuestionParams, MarketParams} from "@ft/src/controllerv2/ControllerStorage.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {Market, MarketDeployParams} from "@ft/lib/Market.sol";
import {TokenHelper} from "@ft/lib/TokenHelper.sol";

/// @notice Per-outcome OO price request params.
struct PriceRequestParams {
    address rewardToken;
    uint256 reward;
    uint256 proposalBond;
    uint256 liveness;
}

/// @title FTUmaAdaptor
/// @notice Bridge between FT Controller V2 markets and UMA Managed Optimistic Oracle V2.
contract FTUmaAdaptor is AccessControlDefaultAdminRules, TokenHelper, ReentrancyGuardTransient {
    //// CONSTANT ////

    bytes32 private constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");

    /// @notice OO ignore price sentinel value.
    int256 internal constant IGNORE_PRICE = type(int256).min;

    IFTControllerV2 public immutable CONTROLLER;

    IOptimisticOracleV2 public immutable ORACLE;

    //// STATES ////

    /// @notice Tracks ancillary to questionOutcome
    mapping(bytes32 ancillary => QuestionOutcome) public questionOutcome;

    /// @notice Per-question state (timing, flags, outcome metadata, retry bitmap).
    mapping(bytes32 questionId => QuestionData) internal _questions;

    //// EVENT ////

    /// @notice Emitted on `deployMarket` so indexers can recover the original creator EOA.
    event AdaptorMarketCreated(
        bytes32 indexed questionId, address indexed market, address indexed creator, uint8 numOutcomes, uint96 timestamp
    );
    event AdaptorOutcomeDisputed(
        bytes32 indexed questionId, uint256 indexed outcomeIndex, uint32 requeryNonce, uint256 refund
    );
    event AdaptorOutcomeRetried(bytes32 indexed questionId, uint256 indexed outcomeIndex);

    //// ERROR ////

    error AdaptorMarketNotRegistered();
    error AdaptorAllOutcomesNo();
    error AdaptorUnauthorizedCaller();
    error AdaptorOutcomeIgnoredByDvm(bytes32 questionId, uint256 outcomeIndex);
    error AdaptorOutcomeUnknown(bytes32 questionId, uint256 outcomeIndex);
    error AdaptorInvalidPrice(bytes32 questionId, uint256 outcomeIndex, int256 price);

    /// @param controller_ FT Controller V2 address.
    /// @param oracle_ UMA Optimistic Oracle V2 address.
    /// @param admin_ Initial DEFAULT_ADMIN_ROLE holder.
    /// @param adminTransferDelay_ Delay (seconds) for admin role transfers.
    constructor(address controller_, address oracle_, address admin_, uint48 adminTransferDelay_)
        AccessControlDefaultAdminRules(adminTransferDelay_, admin_)
    {
        CONTROLLER = IFTControllerV2(controller_);
        ORACLE = IOptimisticOracleV2(oracle_);
    }

    //// EXTERNAL ////

    /// @notice Deploy a market and open one UMA price request per outcome.
    /// @param paramsQuestion Question metadata.
    /// @param paramsMarket Market parameters forwarded to the controller.
    /// @param paramsRequest Per-outcome UMA request configuration.
    /// @param otSeed Seed amount per outcome token.
    /// @return questionId From the controller.
    /// @return market Deployed market address.
    function deployMarket(
        QuestionParams calldata paramsQuestion,
        MarketParams calldata paramsMarket,
        PriceRequestParams calldata paramsRequest,
        uint256 otSeed
    ) external nonReentrant onlyRole(QUESTION_CREATOR_ROLE) returns (bytes32 questionId, address market) {
        uint256 numOutcomes = paramsQuestion.outcomeNames.length;
        address collateral = paramsMarket.collateral;
        uint256 parentTokenId = paramsMarket.parentTokenId;

        uint256 costSeedExact = _getSeedCost(collateral, parentTokenId, paramsMarket.curve, numOutcomes, otSeed);

        // pull collateral
        _pullAndApprove(collateral, parentTokenId, address(CONTROLLER), costSeedExact);

        // pull reward
        _pullAndApprove(paramsRequest.rewardToken, NULL_PARENT_ID, address(ORACLE), paramsRequest.reward * numOutcomes);

        (questionId, market) = CONTROLLER.deployMarket(paramsQuestion, paramsMarket, address(this), otSeed);

        // request price from OO
        _setupRequestPrice(questionId, paramsQuestion, paramsRequest);

        // Adaptor shouldn't hold fund, refund the balance back to the caller
        _refundAndUnapprove(collateral, parentTokenId, msg.sender, _selfBalance(collateral, parentTokenId));

        emit AdaptorMarketCreated(questionId, market, msg.sender, uint8(numOutcomes), uint96(block.timestamp));
    }

    /// @notice OO callback when a proposed price is disputed.
    /// @param ancillaryData Identifies the outcome via keccak256 lookup.
    /// @param refund Bond/reward returned by UMA; recycled as retry reward on the first
    ///        dispute, otherwise refunded immediately to the question creator.
    function priceDisputed(
        bytes32,
        /*identifier*/
        uint256,
        /*timestamp*/
        bytes calldata ancillaryData,
        uint256 refund
    )
        external
        nonReentrant
    {
        if (msg.sender != address(ORACLE)) revert AdaptorUnauthorizedCaller();

        QuestionOutcome memory ref = questionOutcome[keccak256(ancillaryData)];

        if (ref.questionId == bytes32(0)) revert AdaptorMarketNotRegistered();

        QuestionData storage data = _questions[ref.questionId];
        uint256 retried = data.retried;
        uint256 outcomeMask = 1 << ref.outcomeIndex;

        uint32 requeryNonce = uint32((retried >> ref.outcomeIndex) & 1);
        emit AdaptorOutcomeDisputed(ref.questionId, ref.outcomeIndex, requeryNonce, refund);

        // Refund if question finalised or retried
        if (IRegistry(address(CONTROLLER)).isFinalised(ref.questionId) || retried & outcomeMask != 0) {
            _transferOut(data.rewardToken, NULL_PARENT_ID, data.creator, refund);
            return;
        }

        data.retried = retried | outcomeMask;
        // retry request price
        _retryRequestPrice(data, ref.questionId, ref.outcomeIndex, 1, refund);
        emit AdaptorOutcomeRetried(ref.questionId, ref.outcomeIndex);
    }

    /// @notice Settle all UMA prices and forward the outcome bitmap to the controller.
    /// @param questionId From deployMarket.
    function resolveOutcome(bytes32 questionId) external nonReentrant {
        QuestionData storage data = _questions[questionId];

        string[] memory names = IRegistry(address(CONTROLLER)).getOutcomeNames(questionId);
        bytes[] memory calls = AncillaryData.settlePrice(data, questionId, address(CONTROLLER), names);
        bytes[] memory results = ORACLE.multicall(calls);

        uint256 bitmap;
        uint256 length = results.length;
        for (uint256 i = 0; i < length; ++i) {
            int256 price = abi.decode(results[i], (int256));

            if (price == IGNORE_PRICE) revert AdaptorOutcomeIgnoredByDvm(questionId, i);
            if (price == 0.5 ether) revert AdaptorOutcomeUnknown(questionId, i);

            if (price == 1 ether) {
                bitmap |= (1 << i); // YES
            } else if (price != 0) {
                // 0 = NO; anything else (other than YES/UNKNOWN/IGNORE handled above) is invalid.
                revert AdaptorInvalidPrice(questionId, i, price);
            }
        }

        if (bitmap == 0) revert AdaptorAllOutcomesNo();

        CONTROLLER.resolveOutcome(questionId, bitmap);
        CONTROLLER.finaliseOutcome(questionId, bitmap);
    }

    /// Top up liquidity on an existing market.
    /// @param market Target market (must already be deployed and unresolved).
    /// @param tokenIds Outcome token IDs to seed.
    /// @param otAmounts Per-outcome token amounts to seed.
    function seedLiquidity(address market, uint256[] calldata tokenIds, uint256[] calldata otAmounts)
        external
        nonReentrant
    {
        bytes32 questionId = IFTMarketV2(market).questionId();
        _requireQuestionCreator(questionId);

        _seedSingleMarket(market, tokenIds, otAmounts);
    }

    /// Add new outcomes to an existing question and seed them in one tx.
    /// @param questionId From deployMarket.
    /// @param names New outcome names (appended after existing outcomes).
    /// @param imageUris Per-new-outcome image URIs (same length as names).
    /// @param markets Markets backed by this question that should receive the new outcomes' seed.
    /// @param otAmounts Per-new-outcome token amounts to seed (same length as names).
    /// @param rewardPerOutcome UMA reward per new outcome (Same token)
    function addOutcomesWithSeed(
        bytes32 questionId,
        string[] calldata names,
        string[] calldata imageUris,
        address[] calldata markets,
        uint256[] calldata otAmounts,
        uint256 rewardPerOutcome
    ) external nonReentrant {
        QuestionData storage data = _requireQuestionCreator(questionId);
        if (otAmounts.length != names.length) revert Errors.AdaptorOtAmountsDoesNotMatch();

        _pullAndApprove(data.rewardToken, NULL_PARENT_ID, address(ORACLE), rewardPerOutcome * names.length);

        CONTROLLER.addOutcomes(questionId, names, imageUris);

        uint256 numOutcomesPrev = data.numOutcomes;
        // overflow check in ancillaryData.requestPrice
        data.numOutcomes = uint8(numOutcomesPrev + names.length);
        _requestPrices(data, questionId, names, numOutcomesPrev, 0, rewardPerOutcome);
        _seedMarkets(questionId, numOutcomesPrev, markets, otAmounts);
    }

    /// Add new outcomes to an existing question
    function addOutcome(bytes32 questionId, string[] calldata names, string[] calldata imageUris) external {
        _requireQuestionCreator(questionId);

        CONTROLLER.addOutcomes(questionId, names, imageUris);
    }

    /// @notice Append ancillary data update for a live question
    /// @param questionId From deployMarket.
    /// @param data Update payload (e.g. clarified resolution criteria).
    function postUpdate(bytes32 questionId, bytes calldata data) external {
        _requireQuestionCreator(questionId);
        CONTROLLER.postUpdate(questionId, data);
    }

    /// @notice Modify the trading end timestamp for a question.
    /// @param questionId From deployMarket.
    /// @param timestampEndNew New end timestamp.
    function modifyTimestampEnd(bytes32 questionId, uint128 timestampEndNew) external {
        _requireQuestionCreator(questionId);
        CONTROLLER.modifyTimestampEnd(questionId, timestampEndNew);
    }

    /// @notice Set the question-level image URI.
    /// @param questionId From deployMarket.
    /// @param imageUri New image URI for the question.
    function setImageUri(bytes32 questionId, string calldata imageUri) external {
        _requireQuestionCreator(questionId);
        CONTROLLER.setImageUri(questionId, imageUri);
    }

    /// @notice Set the image URI for a specific outcome.
    /// @param questionId From deployMarket.
    /// @param indexOutcome Outcome index.
    /// @param imageUri New image URI for the outcome.
    function setOutcomeImageUri(bytes32 questionId, uint256 indexOutcome, string calldata imageUri) external {
        _requireQuestionCreator(questionId);
        CONTROLLER.setOutcomeImageUri(questionId, indexOutcome, imageUri);
    }

    //// INTERNAL ////

    /// @dev Build the new-outcome `tokenIds` array and seed each market.
    function _seedMarkets(
        bytes32 questionId,
        uint256 numOutcomesPrev,
        address[] calldata markets,
        uint256[] calldata otAmounts
    ) internal {
        uint256 numNew = otAmounts.length;
        uint256[] memory tokenIds = new uint256[](numNew);
        for (uint256 i = 0; i < numNew; ++i) {
            tokenIds[i] = Market.toTokenId(numOutcomesPrev + i);
        }
        for (uint256 i = 0; i < markets.length; ++i) {
            address market = markets[i];
            // Sanity: each user-supplied market must back this question
            if (IFTMarketV2(market).questionId() != questionId) {
                revert Errors.AdaptorMarketDoesNotMatchQuestionId();
            }
            _seedSingleMarket(market, tokenIds, otAmounts);
        }
    }

    /// @dev Writes the QuestionData header and submits the initial per-outcome OO requests.
    function _setupRequestPrice(
        bytes32 questionId,
        QuestionParams calldata paramsQuestion,
        PriceRequestParams calldata paramsRequest
    ) internal {
        QuestionData storage data = _questions[questionId];

        data.rewardToken = paramsRequest.rewardToken;
        data.timestamp = uint96(block.timestamp);
        data.creator = msg.sender;
        data.proposalBond = paramsRequest.proposalBond;
        // Count bounds checked in `AncillaryData.requestPrice`; safe to cast.
        data.numOutcomes = uint8(paramsQuestion.outcomeNames.length);
        data.liveness = uint32(paramsRequest.liveness);
        data.title = paramsQuestion.title;
        data.description = paramsQuestion.ancillaryData;

        _requestPrices(data, questionId, paramsQuestion.outcomeNames, 0, 0, paramsRequest.reward);
    }

    /// @dev Builds the per-outcome OO request multicall
    function _requestPrices(
        QuestionData storage data,
        bytes32 questionId,
        string[] memory names,
        uint256 startIndex,
        uint256 nonce,
        uint256 reward
    ) private {
        bytes[] memory calls = AncillaryData.requestPrice(
            questionOutcome, data, questionId, address(CONTROLLER), names, startIndex, nonce, reward
        );
        ORACLE.multicall(calls);
    }

    /// @dev Re-submits a single outcome's OO request under a fresh nonce.
    function _retryRequestPrice(
        QuestionData storage data,
        bytes32 questionId,
        uint256 outcomeIndex,
        uint256 nonce,
        uint256 reward
    ) internal {
        if (reward > 0) _forceApprove(data.rewardToken, NULL_PARENT_ID, address(ORACLE), reward);

        string[] memory outcomeNames = IRegistry(address(CONTROLLER)).getOutcomeNames(questionId);
        string[] memory names = new string[](1);
        names[0] = outcomeNames[outcomeIndex];

        _requestPrices(data, questionId, names, outcomeIndex, nonce, reward);
    }

    /// @dev Seeds a single market with the given token IDs and amounts.
    function _seedSingleMarket(address market, uint256[] memory tokenIds, uint256[] memory otAmounts) internal {
        MarketDeployParams memory p = IFTMarketV2(market).readMarketDeployParams();

        // calSeedCostByOtDeltas can be state-modifying; staticcall keeps adapter side-effect-free
        (bool ok, bytes memory ret) =
            p.curve.staticcall(abi.encodeCall(IFTCurve.calSeedCostByOtDeltas, (market, tokenIds, otAmounts, "")));
        if (!ok) revert Errors.FactorySeedCallFailed();
        (uint256[] memory collateralsIn,) = abi.decode(ret, (uint256[], uint256[]));

        uint256 costSeedExact;
        uint256 lenIn = collateralsIn.length;
        for (uint256 j = 0; j < lenIn; ++j) {
            costSeedExact += collateralsIn[j];
        }
        if (costSeedExact == 0) return; // free seed not allowed; skip silently

        // pull collateral
        _pullAndApprove(p.collateral, p.parentTokenId, address(CONTROLLER), costSeedExact);

        CONTROLLER.seedLiquidity(market, tokenIds, otAmounts);

        _refundAndUnapprove(p.collateral, p.parentTokenId, msg.sender, _selfBalance(p.collateral, p.parentTokenId));
    }

    /// @dev Pull `amount` of `token` (parent id `parentId`) from msg.sender and approve `spender`.
    function _pullAndApprove(address token, uint256 parentId, address spender, uint256 amount) private {
        if (amount == 0) return;
        _transferIn(token, parentId, msg.sender, amount);
        _forceApprove(token, parentId, spender, amount);
    }

    /// @dev refund and reset approval
    function _refundAndUnapprove(address token, uint256 parentId, address to, uint256 amount) private {
        if (amount == 0) return;
        _transferOut(token, parentId, to, amount);
        _forceApprove(token, parentId, address(CONTROLLER), 0);
    }

    //// VIEW ////

    /// @notice check if Question is ready to resolve
    /// @param questionId From deployMarket.
    function ready(bytes32 questionId) external view returns (bool) {
        QuestionData storage data = _questions[questionId];
        if (data.timestamp == 0) return false;
        IRegistry controller = IRegistry(address(CONTROLLER));
        if (controller.isPaused()) return false;
        if (controller.isFinalised(questionId)) return false;
        if (controller.getOutcomeAnswer(questionId) != 0) return false;

        string[] memory names = controller.getOutcomeNames(questionId);
        return AncillaryData.hasAllPrices(data, questionId, ORACLE, address(CONTROLLER), names);
    }

    /// @dev Reverts unless `msg.sender` deployed `questionId`
    function _requireQuestionCreator(bytes32 questionId) private view returns (QuestionData storage data) {
        data = _questions[questionId];
        if (data.creator != msg.sender) revert AdaptorUnauthorizedCaller();
    }

    function _getSeedCost(address collateral, uint256 parentTokenId, address curve, uint256 numOutcomes, uint256 otSeed)
        internal
        view
        returns (uint256 costSeedExact)
    {
        uint8 decimals = _collateralDecimals(collateral, parentTokenId);
        uint80 feeRateDefault = CONTROLLER.getDefaultFeeRate();

        uint256[] memory tokenIds = new uint256[](numOutcomes);
        uint256[] memory otDeltas = new uint256[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            tokenIds[i] = Market.toTokenId(i);
            otDeltas[i] = otSeed;
        }

        (costSeedExact,) = IFTCurve(curve).simSeed(tokenIds, otDeltas, decimals, feeRateDefault);
    }
}
