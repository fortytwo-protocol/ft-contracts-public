// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {QuestionParams, MarketParams} from "@ft/src/controllerv2/ControllerStorage.sol";

interface IFTControllerV2 {
    /**
     * @notice assumes 1 OT seed amount for all outcomes
     */
    function deployMarket(
        QuestionParams calldata paramsQuestion,
        MarketParams calldata paramsMarket,
        address oracle,
        uint256 otSeed
    ) external returns (bytes32 questionId, address market);

    function seedLiquidity(address market, uint256[] calldata tokenIds, uint256[] calldata otAmounts) external;
    function postUpdate(bytes32 questionId, bytes calldata update) external;

    function addOutcomes(bytes32 questionId, string[] calldata names, string[] calldata imageUris) external;
    function modifyTimestampEnd(bytes32 questionId, uint128 timestampEndNew) external;
    function setImageUri(bytes32 questionId, string calldata imageUri) external;
    function setOutcomeImageUri(bytes32 questionId, uint256 indexOutcome, string calldata imageUri) external;

    function resolveOutcome(bytes32 questionId, uint256 answer) external;
    function unresolveOutcome(bytes32 questionId) external;
    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge) external;

    function predictMarketAddress(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint128 timestampStart
    ) external view returns (address);

    function getDefaultFeeRate() external view returns (uint80);
}
