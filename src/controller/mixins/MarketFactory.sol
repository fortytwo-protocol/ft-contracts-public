// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@solady/utils/SSTORE2.sol";
import "@ft/src/FTMarket.sol";
import "@ft/src/interfaces/IRegistry.sol";
import "@ft/src/interfaces/IFTMarket.sol";
import "@ft/src/interfaces/IFTCurve.sol";
import {MarketDeployParams, SwapParams, Market} from "@ft/lib/Market.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/Event.sol";
import "@ft/lib/FTMath.sol";
import "@ft/lib/TokenHelper.sol";
import "@ft/lib/Market.sol";

abstract contract MarketFactory is HasFTEvents, TokenHelper {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FTMath for uint256;

    IRegistry public immutable registry;

    bytes internal constant EMPTY_BYTES = "";
    address public immutable FTMARKET_INIT_CODE_STORE;

    EnumerableSet.AddressSet private markets;

    constructor(address _registry) {
        registry = IRegistry(_registry);
        FTMARKET_INIT_CODE_STORE = SSTORE2.write(type(FTMarket).creationCode);
    }

    function _deployMarket(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint128 startBy
    ) internal returns (address) {
        if (collateral == address(0)) revert Errors.FactoryInvalidCollateral();
        if (curve == address(0)) revert Errors.FactoryInvalidCurve();
        if (parentTokenId != NULL_PARENT_ID) {
            // validate 6909 as FTMarket
            if (!markets.contains(collateral)) {
                revert Errors.Registry6909MustBeRegisteredMarket();
            }

            if (!Market.isValidTokenId(parentTokenId)) {
                revert Errors.RegistryInvalidTokenIdAsCollateral();
            }

            uint256 numOutcomes = registry.getNumOutcomes(IFTMarket(collateral).questionId());
            uint256 parentTokenIdMax = Market.toTokenId(numOutcomes - 1);
            if (parentTokenId > parentTokenIdMax) {
                revert Errors.RegistryTokenIdNotCreatedForMarket();
            }
        }
        uint128 timestampEnd = registry.getOutcomeEnd(questionId);
        uint128 timestampStart = FTMath.max128(startBy, block.timestamp.toUint128());
        if (timestampEnd <= timestampStart) revert("why did you launch this market?");

        MarketDeployParams memory params = MarketDeployParams({
            collateral: collateral,
            parentTokenId: parentTokenId,
            questionId: questionId,
            curve: curve,
            timestampStart: timestampStart
        });
        address market = _create2(params);
        if (market == address(0)) revert Errors.FactoryUnsuccessfulMarketDeployment();

        markets.add(market);

        emit CreateNewMarket(market, collateral, parentTokenId, questionId, curve, timestampStart);

        return market;
    }

    function _seedLiquidity(
        address market,
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint256 otSeed
    ) internal {
        // this is very dirty, because you can't go through router (access control) and you can't call mint (before market start)...
        if (otSeed == 0) revert Errors.FactoryInvalidSeedAmount();

        uint256 numOutcomes = registry.getNumOutcomes(questionId);

        _forceApprove(collateral, parentTokenId, market, type(uint256).max);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            (uint256 collateralRequired,) = IFTCurve(curve).calMintCostByOtDelta(market, tokenId, otSeed, EMPTY_BYTES);

            // each seed must have a separate transferFrom, a swap can change the price of the next token
            _transferFrom(collateral, parentTokenId, msg.sender, address(this), collateralRequired);
            IFTMarket(market).seed(tokenId, otSeed, EMPTY_BYTES);
        }
        _forceApprove(collateral, parentTokenId, market, 0);
    }

    function _create2(MarketDeployParams memory params) internal returns (address newMarket) {
        bytes32 salt = _getSalt(params);
        bytes memory creationCode = _getCreationCodeWithArgs(params);
        assembly ("memory-safe") {
            newMarket := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
    }

    function _getSalt(MarketDeployParams memory params) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(params.collateral, params.parentTokenId, params.questionId, params.curve, params.timestampStart)
        );
    }

    function _getCreationCodeWithArgs(MarketDeployParams memory params) internal view returns (bytes memory) {
        return abi.encodePacked(
            SSTORE2.read(FTMARKET_INIT_CODE_STORE),
            abi.encode(
                address(registry), // registry
                address(this), // factory
                params.collateral,
                params.parentTokenId,
                params.questionId,
                params.curve,
                params.timestampStart
            )
        );
    }

    function _computeCounterfactual(MarketDeployParams memory params) internal view returns (address) {
        bytes32 salt = _getSalt(params);
        bytes memory creationCode = _getCreationCodeWithArgs(params);

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode)));

        return address(uint160(uint256(hash)));
    }

    function predictMarketAddress(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint128 timestampStart
    ) external view returns (address) {
        MarketDeployParams memory params = MarketDeployParams({
            collateral: collateral,
            parentTokenId: parentTokenId,
            questionId: questionId,
            curve: curve,
            timestampStart: timestampStart
        });

        return _computeCounterfactual(params);
    }

    function isMarket(address market) external view returns (bool) {
        return markets.contains(market);
    }
}
