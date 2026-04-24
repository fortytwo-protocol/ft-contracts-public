// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFTControllerV2} from "@ft/src/interfaces/IFTControllerV2.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IFTMarketV2} from "@ft/src/interfaces/IFTMarketV2.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {QuestionParams, MarketParams} from "@ft/src/controllerv2/ControllerStorage.sol";
import {Market, MarketDeployParams} from "@ft/lib/Market.sol";
import {TokenHelper} from "@ft/lib/TokenHelper.sol";

contract FTAdaptor is AccessControlDefaultAdminRules, TokenHelper, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 private constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 private constant QUESTION_RESOLVER_ROLE = keccak256("QUESTION_RESOLVER_ROLE");
    bytes32 private constant QUESTION_FINALISER_ROLE = keccak256("QUESTION_FINALISER_ROLE");

    bytes private constant EMPTY_BYTES = "";

    IFTControllerV2 public immutable controller;

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

        uint256 costSeedExact =
            _getSeedCost(collateral, parentTokenId, paramsMarket.curve, paramsQuestion.outcomeNames.length, otSeed);

        _transferIn(collateral, parentTokenId, msg.sender, costSeedExact);
        _forceApprove(collateral, parentTokenId, address(controller), costSeedExact);

        (questionId, market) =
            IFTControllerV2(address(controller)).deployMarket(paramsQuestion, paramsMarket, address(this), otSeed);

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
        controller.seedLiquidity(market, tokenIds, otAmounts);
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

    function modifyTimestampEnd(bytes32 questionId, uint128 timestampEndNew)
        external
        nonReentrant
        onlyRole(QUESTION_CREATOR_ROLE)
    {
        controller.modifyTimestampEnd(questionId, timestampEndNew);
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) external nonReentrant onlyRole(QUESTION_RESOLVER_ROLE) {
        controller.resolveOutcome(questionId, answer);
    }

    function unresolveOutcome(bytes32 questionId) external nonReentrant onlyRole(QUESTION_RESOLVER_ROLE) {
        controller.unresolveOutcome(questionId);
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
