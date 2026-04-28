// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";

import {HasFTEvents} from "@ft/lib/Event.sol";
import {TokenHelper} from "@ft/lib/TokenHelper.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {Market, MarketDeployParams} from "@ft/lib/Market.sol";
import {QuestionV2} from "@ft/lib/QuestionV2.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {FTMarketV2} from "@ft/src/FTMarketV2.sol";
import {
    ControllerStorage,
    GovernanceStorage,
    QuestionStateV2,
    RegistryStorage
} from "@ft/src/controllerv2/ControllerStorage.sol";

abstract contract MarketFactory is Initializable, HasFTEvents, TokenHelper {
    using EnumerableSet for EnumerableSet.AddressSet;
    using QuestionV2 for QuestionStateV2;
    using FTMath for uint256;

    bytes private constant EMPTY_BYTES = "";

    address public immutable FTMARKET_INIT_CODE_STORE;
    uint256 private constant MIN_PARENT_OT_SEED = FTMath.FT_ONE;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        FTMARKET_INIT_CODE_STORE = SSTORE2.write(type(FTMarketV2).creationCode);
    }

    function _deployMarket(
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint128 startBy
    ) internal returns (address) {
        GovernanceStorage storage gov = ControllerStorage.governance();
        RegistryStorage storage reg = ControllerStorage.registry();

        if (collateral == address(0)) revert Errors.FactoryInvalidCollateral();
        if (curve == address(0)) revert Errors.FactoryInvalidCurve();
        if (!gov.whitelistedCurves[curve]) revert Errors.FactoryCurveNotAllowed();
        if (parentTokenId != NULL_PARENT_ID) {
            // validate 6909 as FTMarket
            if (!reg.markets.contains(collateral)) revert Errors.Registry6909MustBeRegisteredMarket();
            if (!Market.isValidTokenId(parentTokenId)) revert Errors.RegistryInvalidTokenIdAsCollateral();

            uint256 numOutcomes = reg.questions[IFTMarket(collateral).questionId()].getNumOutcomes();
            uint256 parentTokenIdMax = Market.toTokenId(numOutcomes - 1);
            if (parentTokenId > parentTokenIdMax) revert Errors.RegistryTokenIdNotCreatedForMarket();
        }

        uint96 timestampEnd = reg.questions[questionId].timestampEnd;
        uint128 timestampStart = FTMath.max128(startBy, block.timestamp.toUint128());
        if (uint128(timestampEnd) <= timestampStart) revert Errors.RegistryInvalidTimestamp();

        MarketDeployParams memory params = MarketDeployParams({
            collateral: collateral,
            parentTokenId: parentTokenId,
            questionId: questionId,
            curve: curve,
            timestampStart: timestampStart
        });
        address market = _create2(params);
        if (market == address(0)) revert Errors.RegistryMarketDeploymentFailed();

        reg.markets.add(market);

        return market;
    }

    function _seedLiquidity(
        address market,
        address collateral,
        uint256 parentTokenId,
        address curve,
        uint256[] memory tokenIds,
        uint256[] memory otAmounts
    ) internal returns (uint256 collateralTotal) {
        // note: calSeedCostByOtDeltas can be state-modifying, and assertion that market address != controller address may not always hold
        (bool ok, bytes memory ret) =
            curve.staticcall(abi.encodeCall(IFTCurve.calSeedCostByOtDeltas, (market, tokenIds, otAmounts, EMPTY_BYTES)));
        if (!ok) revert Errors.FactorySeedCallFailed();
        (uint256[] memory collateralsIn,) = abi.decode(ret, (uint256[], uint256[]));

        uint256 len = collateralsIn.length;
        for (uint256 i = 0; i < len; ++i) {
            collateralTotal += collateralsIn[i];
        }

        // note: collateral must be transferred before calling seed
        _transferFrom(collateral, parentTokenId, msg.sender, market, collateralTotal);
        uint256 collateralSeed = FTMarketV2(market).seed(tokenIds, otAmounts, EMPTY_BYTES);

        if (collateralSeed != collateralTotal) revert Errors.FactorySeedCostMismatch();
    }

    function _create2(MarketDeployParams memory params) private returns (address newMarket) {
        bytes32 salt = _getSalt(params);
        bytes memory creationCode = _getCreationCodeWithArgs(params);
        assembly ("memory-safe") {
            newMarket := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
    }

    function _getSalt(MarketDeployParams memory params) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                params.collateral,
                params.parentTokenId,
                params.questionId,
                params.curve,
                params.timestampStart,
                block.chainid
            )
        );
    }

    function _getCreationCodeWithArgs(MarketDeployParams memory params) internal view returns (bytes memory) {
        return abi.encodePacked(
            SSTORE2.read(FTMARKET_INIT_CODE_STORE),
            abi.encode(
                address(this), // note: assumption that this is registry (upgradeability can break)
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
}
