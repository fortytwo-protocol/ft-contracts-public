// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IFTControllerV2} from "@ft/src/interfaces/IFTControllerV2.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IFTMarketV2} from "@ft/src/interfaces/IFTMarketV2.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {QuestionParams, MarketParams} from "@ft/src/controllerv2/ControllerStorage.sol";
import {Market, MarketDeployParams} from "@ft/lib/Market.sol";
import {TokenHelper} from "@ft/lib/TokenHelper.sol";
import {FTMath} from "@ft/lib/FTMath.sol";

/**
 * @notice the core differences between FTAdaptor is:
 * - Introduction of co-resolvers with different privilege hierachy
 * RESOLVER: resolve, unresolve, lock and unlock. Any action disables PROPOSER's ability to act on the question
 * PROPOSER: resolve, unresolve, lock and unlock unless RESOLVER overrides
 *
 * - Lock & Unlock function that closes trading for a question
 * Should ONLY be used to close a market when the result is known to be out, but exact answer is unclear.
 * Locking is preferred over resolving incorrectly as there can be negative downstream implications especially wrt disputes.
 *
 * @notice CREATOR & FINALISER retain their original roles and capabilities with no changes
 */
contract FTCournotAdaptor is AccessControlDefaultAdminRules, TokenHelper, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using FTMath for *;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 private constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 private constant QUESTION_RESOLVER_ROLE = keccak256("QUESTION_RESOLVER_ROLE");
    bytes32 private constant QUESTION_FINALISER_ROLE = keccak256("QUESTION_FINALISER_ROLE");
    bytes32 private constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bytes private constant EMPTY_BYTES = "";
    uint256 private constant EMPTY_ANSWER = 0;

    IFTControllerV2 public immutable controller;

    struct ResolutionState {
        // override prevents proposer from interacting with question,
        // for complete disable of the proposer, you should revokeRole() instead
        bool isOverride;
        bool lockDisabled; // default false => question can be locked
        uint96 timestampEndPrev; // 0 => no previous timestamp end
    }

    mapping(bytes32 questionId => ResolutionState state) public resolutionStates;

    EnumerableSet.AddressSet private blacklistedCurves;

    event ProposerOverridden(bytes32 indexed questionId, bool isOverride);
    event QuestionLockOverridden(bytes32 indexed questionId, bool lockDisabled);
    event QuestionLocked(bytes32 indexed questionId, address locker, uint96 timestampNew);
    event QuestionUnlocked(bytes32 indexed questionId, address unlocker, uint96 timestampPrelock);
    event CurveBlacklisted(address indexed curve, bool isBlacklisted);

    /**
     * @param answer there may be a state drift from core events, but answer == 0 refers to unresolve()
     */
    event AnswerProposed(bytes32 indexed questionId, address proposer, uint256 answer);

    /**
     * @param answer there may be a state drift from core events, but answer == 0 refers to unresolve()
     */
    event AnswerResolved(bytes32 indexed questionId, address resolver, uint256 answer);

    constructor(address _controller, address admin_, uint48 adminTransferDelay_)
        AccessControlDefaultAdminRules(adminTransferDelay_, admin_)
    {
        controller = IFTControllerV2(_controller);
    }

    function deployMarket(QuestionParams calldata paramsQuestion, MarketParams calldata paramsMarket, uint256 otSeed)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
        returns (bytes32 questionId, address market)
    {
        address collateral = paramsMarket.collateral;
        uint256 parentTokenId = paramsMarket.parentTokenId;

        require(!blacklistedCurves.contains(paramsMarket.curve), Errors.AdaptorCurveBlacklisted());

        uint256 costSeedExact =
            _getSeedCost(collateral, parentTokenId, paramsMarket.curve, paramsQuestion.outcomeNames.length, otSeed);

        _transferIn(collateral, parentTokenId, msg.sender, costSeedExact);
        _forceApprove(collateral, parentTokenId, address(controller), costSeedExact);

        (questionId, market) = controller.deployMarket(paramsQuestion, paramsMarket, address(this), otSeed);

        uint256 remaining = _selfBalance(collateral, parentTokenId);
        if (remaining > 0) {
            _transferOut(collateral, parentTokenId, msg.sender, remaining);
            _forceApprove(collateral, parentTokenId, address(controller), 0); // reset to 0, not all approval spent
        }
    }

    function addOutcome(bytes32 questionId, string[] calldata names, string[] calldata imageUris)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        controller.addOutcomes(questionId, names, imageUris);
    }

    function seedLiquidity(address market, uint256[] calldata tokenIds, uint256[] calldata otAmounts)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        _seedSingleMarket(market, tokenIds, otAmounts);
    }

    /**
     * @dev to avoid incorrect seeding, will revert on market's questionId mismatch (market.questionId != questionId)
     * @dev to avoid incorrect seeding, tokenId is computed on-chain to avoid client-side errors
     */
    function addOutcomeWithSeed(
        bytes32 questionId,
        string[] calldata names,
        string[] calldata imageUris,
        address[] calldata markets,
        uint256[] calldata otAmounts
    ) external nonReentrant onlyRole(QUESTION_CREATOR_ROLE) {
        // names <> imageUris is already handled in controller
        // but as we call seedLiquidity separately, sanity check is done
        require(otAmounts.length == names.length, Errors.AdaptorOtAmountsDoesNotMatch());

        uint256 numOutcomesPrev = IRegistry(address(controller)).getNumOutcomes(questionId);
        controller.addOutcomes(questionId, names, imageUris);

        // compute onchain to avoid client-side passing in wrong values due to off-by-one
        uint256 numOutcomesDelta = otAmounts.length;
        uint256[] memory tokenIds = new uint256[](numOutcomesDelta);
        for (uint256 i = 0; i < numOutcomesDelta; ++i) {
            tokenIds[i] = Market.toTokenId(numOutcomesPrev + i);
        }

        uint256 len = markets.length;
        for (uint256 i = 0; i < len; ++i) {
            address market = markets[i];
            require(IFTMarketV2(market).questionId() == questionId, Errors.AdaptorMarketDoesNotMatchQuestionId());
            _seedSingleMarket(market, tokenIds, otAmounts);
        }
    }

    function modifyTimestampEnd(bytes32 questionId, uint128 timestampEndNew)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        ResolutionState storage state = resolutionStates[questionId];
        if (state.timestampEndPrev != 0) {
            state.timestampEndPrev = 0; // reset lock/unlock
        }

        controller.modifyTimestampEnd(questionId, timestampEndNew);
    }

    /**
     * @dev MUST revert if account is not a resolver or is not an overriden proposer
     */
    function _authResolverOrProposer(ResolutionState storage state, bytes32 questionId)
        internal
        returns (bool isResolver)
    {
        isResolver = hasRole(QUESTION_RESOLVER_ROLE, msg.sender);
        if (isResolver) {
            // note: resolver can also be proposer; the higher privilege wins
            if (!state.isOverride) {
                state.isOverride = true;
                emit ProposerOverridden(questionId, true);
            }
        } else if (hasRole(PROPOSER_ROLE, msg.sender)) {
            require(!state.isOverride, Errors.AdaptorProposerOverridden());
        } else {
            revert Errors.AdaptorAccessControlUnauthorizedAccount();
        }
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) external nonReentrant {
        ResolutionState storage state = resolutionStates[questionId];
        bool isResolver = _authResolverOrProposer(state, questionId);
        if (isResolver) {
            emit AnswerResolved(questionId, msg.sender, answer);
        } else {
            emit AnswerProposed(questionId, msg.sender, answer);
        }

        controller.resolveOutcome(questionId, answer);
    }

    function unresolveOutcome(bytes32 questionId) external nonReentrant {
        ResolutionState storage state = resolutionStates[questionId];
        bool isResolver = _authResolverOrProposer(state, questionId);
        if (isResolver) {
            emit AnswerResolved(questionId, msg.sender, EMPTY_ANSWER);
        } else {
            emit AnswerProposed(questionId, msg.sender, EMPTY_ANSWER);
        }

        controller.unresolveOutcome(questionId);
    }

    /**
     * @notice locks the question by modifying the question end timestamp to the past.
     * Should ONLY be used for questions that resolve early & with low confidence as there are downstream implications
     * @dev question MUST be currently open OR not currently locked
     */
    function lockQuestion(bytes32 questionId) external nonReentrant {
        ResolutionState storage state = resolutionStates[questionId];
        _authResolverOrProposer(state, questionId);
        require(!state.lockDisabled, Errors.AdaptorCannotBeLocked());

        // note: check covers both question naturally ended & previously locked by adaptor
        uint128 timestampEnd = IRegistry(address(controller)).getOutcomeEnd(questionId);
        require(timestampEnd > block.timestamp, Errors.AdaptorQuestionAlreadyLocked());
        // note: safe cast uint128 -> uint96
        state.timestampEndPrev = timestampEnd.to128Uint96();

        controller.modifyTimestampEnd(questionId, uint128(block.timestamp - 1));

        emit QuestionLocked(questionId, msg.sender, uint96(block.timestamp - 1));
    }

    /**
     * @notice unlocks the question by reverting to pre-lock end timestamp.
     * @dev question MUST be previously locked and its pre-lock end must not have passed
     * @dev unlocking is possible even with lockDisabled as recovery can be a critical action
     */
    function unlockQuestion(bytes32 questionId) external nonReentrant {
        ResolutionState storage state = resolutionStates[questionId];
        _authResolverOrProposer(state, questionId);

        // note: if pre-lock is in the past, use modifyTimestampEnd directly
        uint96 timestampEnd = state.timestampEndPrev;
        require(timestampEnd != 0, Errors.AdaptorMarketNotLocked());
        require(timestampEnd >= block.timestamp, Errors.AdaptorPrelockTimestampAlreadyPassed());

        state.timestampEndPrev = 0;
        controller.modifyTimestampEnd(questionId, timestampEnd.to96Uint128());

        emit QuestionUnlocked(questionId, msg.sender, timestampEnd);
    }

    function overrideQuestion(bytes32 questionId, bool isOverride)
        external
        nonReentrant
        onlyRole(QUESTION_RESOLVER_ROLE)
    {
        ResolutionState storage state = resolutionStates[questionId];
        if (state.isOverride == isOverride) return;

        state.isOverride = isOverride;
        emit ProposerOverridden(questionId, isOverride);
    }

    function overrideLockDisabled(bytes32 questionId, bool disabled)
        external
        nonReentrant
        onlyRole(QUESTION_RESOLVER_ROLE)
    {
        ResolutionState storage state = resolutionStates[questionId];
        if (state.lockDisabled == disabled) return;

        state.lockDisabled = disabled;
        emit QuestionLockOverridden(questionId, disabled);
    }

    function isOverridden(bytes32 questionId) external view returns (bool) {
        return resolutionStates[questionId].isOverride;
    }

    function isLockDisabled(bytes32 questionId) external view returns (bool) {
        return resolutionStates[questionId].lockDisabled;
    }

    /**
     * @notice the core goal of blacklisting is not security or gatekeep, but is to ensure operational
     * integrity s.t a market is not created using a curve that is explicitly avoided by the adaptor
     */
    function setBlacklistedCurve(address curve, bool blacklist) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(curve != address(0), Errors.AdaptorInvalidCurve());

        if (blacklist) {
            bool isAdded = blacklistedCurves.add(curve);

            if (isAdded) {
                emit CurveBlacklisted(curve, blacklist);
            }
        } else {
            bool isRemoved = blacklistedCurves.remove(curve);

            if (isRemoved) {
                emit CurveBlacklisted(curve, blacklist);
            }
        }
    }

    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge)
        external
        nonReentrant
        onlyRole(QUESTION_FINALISER_ROLE)
    {
        controller.finaliseOutcome(questionId, answerChallenge);
    }

    function postUpdate(bytes32 questionId, bytes calldata data) external nonReentrant onlyRole(QUESTION_CREATOR_ROLE) {
        controller.postUpdate(questionId, data);
    }

    function setImageUri(bytes32 questionId, string calldata imageUri)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        controller.setImageUri(questionId, imageUri);
    }

    function setOutcomeImageUri(bytes32 questionId, uint256 indexOutcome, string calldata imageUri)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        controller.setOutcomeImageUri(questionId, indexOutcome, imageUri);
    }

    function isCurveBlacklisted(address curve) external view returns (bool) {
        return blacklistedCurves.contains(curve);
    }

    function getCurveBlacklist() external view returns (address[] memory) {
        return blacklistedCurves.values();
    }

    /**
     * @dev transfers and approves per-market as each market can have different collaterals
     */
    function _seedSingleMarket(address market, uint256[] memory tokenIds, uint256[] memory otAmounts) internal {
        MarketDeployParams memory p = IFTMarketV2(market).readMarketDeployParams();

        // note: calSeedCostByOtDeltas can be state-modifying, and assertion that market address != adaptor address may not always hold
        (bool ok, bytes memory ret) = p.curve
            .staticcall(abi.encodeCall(IFTCurve.calSeedCostByOtDeltas, (market, tokenIds, otAmounts, EMPTY_BYTES)));
        if (!ok) revert Errors.FactorySeedCallFailed();
        (uint256[] memory collateralsIn,) = abi.decode(ret, (uint256[], uint256[]));

        uint256 costSeedExact;
        uint256 lenIn = collateralsIn.length;
        for (uint256 j = 0; j < lenIn; ++j) {
            costSeedExact += collateralsIn[j];
        }
        if (costSeedExact == 0) return; // no-op, free seed is not allowed either (breaks market)

        _transferIn(p.collateral, p.parentTokenId, msg.sender, costSeedExact);
        _forceApprove(p.collateral, p.parentTokenId, address(controller), costSeedExact);
        controller.seedLiquidity(market, tokenIds, otAmounts);

        uint256 remaining = _selfBalance(p.collateral, p.parentTokenId);
        if (remaining > 0) {
            _transferOut(p.collateral, p.parentTokenId, msg.sender, remaining);
            _forceApprove(p.collateral, p.parentTokenId, address(controller), 0); // reset to 0, not all approval spent
        }
    }

    function _getSeedCost(address collateral, uint256 parentTokenId, address curve, uint256 numOutcomes, uint256 otSeed)
        internal
        view
        returns (uint256 costSeedExact)
    {
        uint8 decimals = _collateralDecimals(collateral, parentTokenId);
        uint80 feeRateDefault = controller.getDefaultFeeRate();

        uint256[] memory tokenIds = new uint256[](numOutcomes);
        uint256[] memory otDeltas = new uint256[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            tokenIds[i] = Market.toTokenId(i);
            otDeltas[i] = otSeed;
        }

        (costSeedExact,) = IFTCurve(curve).simSeed(tokenIds, otDeltas, decimals, feeRateDefault);
    }
}
