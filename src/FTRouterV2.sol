// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";
import {IFTMarketV2} from "@ft/src/interfaces/IFTMarketV2.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {MarketDeployParams, SwapParams} from "@ft/lib/Market.sol";
import {Market} from "@ft/lib/Market.sol";
import {TokenHelper} from "@ft/lib/TokenHelper.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {Integrator} from "@ft/lib/Integrator.sol";
import {Call, Result} from "@ft/src/router/Multicallbackable.sol";
import {FTMarketController} from "@ft/src/controller/FTMarketController.sol";
import {FTControllerV2} from "@ft/src/controllerv2/FTControllerV2.sol";
import {HasFTEvents} from "@ft/lib/Event.sol";

struct IntegratorParams {
    address integrator;
    uint256 integratorFeeBps;
}

contract FTRouterV2 is Initializable, ReentrancyGuardTransient, TokenHelper, HasFTEvents {
    uint256 public constant MAXIMUM_INTEGRATOR_FEE_BPS = 1000; // 10%

    // used to hold everything required for mints. primarily to avoid stack too deep issues
    struct MintPointer {
        uint256 otOut;
        uint256 collateralIn;
        uint256 collateralToIntegrator;
        uint256 collateralInTotal;
        address collateral;
        uint256 parentTokenId;
    }

    // used to hold everything required for redeems. primarily to avoid stack too deep issues
    struct RedeemPointer {
        uint256 otIn;
        uint256 collateralOut;
        uint256 collateralToIntegrator;
        uint256 collateralToUser;
        address collateral;
        uint256 parentTokenId;
    }

    FTMarketController private immutable CONTROLLER_V1;
    FTControllerV2 private immutable CONTROLLER_V2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address controllerV1_, address controllerV2_) {
        if (controllerV1_ == address(0) || controllerV2_ == address(0)) revert Errors.MarketZeroAddress();

        CONTROLLER_V1 = FTMarketController(controllerV1_);
        CONTROLLER_V2 = FTControllerV2(controllerV2_);

        _disableInitializers();
    }

    function initialize() external initializer {
        // empty to prevent potential issues on future upgrades and align with FTControllerV2's initializedVersion
    }

    function multicall(Call[] calldata calls) external returns (Result[] memory returnDatas) {
        uint256 length = calls.length;
        returnDatas = new Result[](length);

        for (uint256 i = 0; i < length; ++i) {
            Call calldata call = calls[i];
            (bool success, bytes memory returnData) = address(this).delegatecall(call.callData);
            if (!success && !call.allowFailure) {
                assembly ("memory-safe") {
                    revert(add(32, returnData), mload(returnData))
                }
            }
            returnDatas[i] = Result({success: success, returnData: returnData});
        }
    }

    /**
     * @notice Simplified generalised swap with slippage protection. For external integrations, please set your own integrator address and fee bps.
     * It is recommended to use the specialised swap (swapMarketV<x>).
     * This can be more difficult to debug and silently suppresses the integrator fee logic for market version 1.
     * New function may be created (i.e swapV2), if new market versions require a change in function signature.
     * @param params swap parameters — DO NOT ROUTE THE FIELDS, THIS FUNCTION ALREADY ROUTES
     * @param dataSwap bytes data consumed by IFTCurve for calculating swap
     * @param dataGuess bytes data consumed by IFTCurve for guessing swap amount (required for exact collateral)
     * @param integrator address receiving integrator fee. address(0) = no fee
     * @param integratorFeeBps fee in basis points (1% = 100 bps). 0 = no fee
     */
    function swap(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory params,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        address integrator,
        uint256 integratorFeeBps
    ) external nonReentrant {
        uint8 version = _getValidatedMarketVersion(market);
        if (version == 1) {
            _swapMarketV1(market, receiver, tokenId, params, dataSwap, dataGuess);
        } else {
            IntegratorParams memory paramsIntegrator =
                IntegratorParams({integrator: integrator, integratorFeeBps: integratorFeeBps});
            _swapMarketV2(market, receiver, tokenId, params, dataSwap, dataGuess, paramsIntegrator);
        }
    }

    /**
     * @notice Simplified swap with slippage protection and minimal function scope for version 1 markets only.
     * It is recommended to use this, but may be difficult if the caller is not aware of market versions.
     * This is also not upgrade-proof as future market versions will require a different function signature.
     * You can use the generalised `swap()` function, but debugging will be more complex.
     */
    function swapMarketV1(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory params,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) external nonReentrant {
        uint8 version = _getValidatedMarketVersion(market);
        if (version != 1) revert Errors.RouterInvalidMarket();

        _swapMarketV1(market, receiver, tokenId, params, dataSwap, dataGuess);
    }

    /**
     * @notice Simplified swap with slippage protection and minimal function scope for version 2 markets only.
     * It is recommended to use this, but may be difficult if the caller is not aware of market versions.
     * This is also not upgrade-proof as future market versions will require a different function signature.
     * You can use the generalised `swap()` function, but debugging will be more complex.
     */
    function swapMarketV2(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory params,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        address integrator,
        uint256 integratorFeeBps
    ) external nonReentrant {
        uint8 version = _getValidatedMarketVersion(market);
        if (version != 2) revert Errors.RouterInvalidMarket();

        _swapMarketV2(
            market,
            receiver,
            tokenId,
            params,
            dataSwap,
            dataGuess,
            IntegratorParams({integrator: integrator, integratorFeeBps: integratorFeeBps})
        );
    }

    /**
     * @notice Simplified version to claim all winning OTs.
     */
    function claimAllSimple(address market, address receiver) external nonReentrant returns (uint256 payout) {
        _getValidatedMarketVersion(market); // note: enforce "onlyMarket"

        address registry = IFTMarketV2(market).registry();
        (,, uint256 numOutcomes,, uint256 answer, bool isFinalised) = IRegistry(registry).getConfig(market);

        if (answer == 0 || !isFinalised) revert Errors.RouterNotClaimableYet();

        uint256 counter = 0;
        uint256[] memory tokenIds = new uint256[](numOutcomes);
        uint256[] memory otToBurn = new uint256[](numOutcomes);

        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            if (Market.isWinner(answer, tokenId)) {
                uint256 otBalance = IFTMarketV2(market).balanceOf(msg.sender, tokenId);
                tokenIds[counter] = tokenId;
                otToBurn[counter] = otBalance;
                _transferIn(market, tokenId, msg.sender, otBalance);
                counter++;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenIds, counter)
            mstore(otToBurn, counter)
        }

        payout = IFTMarketV2(market).claim(receiver, tokenIds, otToBurn);
    }

    function controllerV1() external view returns (address) {
        return address(CONTROLLER_V1);
    }

    function controllerV2() external view returns (address) {
        return address(CONTROLLER_V2);
    }

    function isMarketVersion(address market) external view returns (uint8) {
        return _getValidatedMarketVersion(market);
    }

    /// @return version 1 for V1, 2 for V2. Reverts if market is not registered.
    function _getValidatedMarketVersion(address market) internal view returns (uint8) {
        if (CONTROLLER_V1.isMarket(market)) return 1;
        if (CONTROLLER_V2.isMarket(market)) return 2;
        revert Errors.RouterInvalidMarket();
    }

    function _swapMarketV1(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory paramsSwap,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) internal {
        if (paramsSwap.amount == 0) revert Errors.RouterInvalidSwapAmount();

        if (paramsSwap.isMint) {
            if (paramsSwap.isExactIn) {
                _mintExactCollateralToOtV1(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap, dataGuess
                );
            } else {
                _mintCollateralToExactOtV1(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap
                );
            }
        } else {
            if (paramsSwap.isExactIn) {
                _redeemExactOtToCollateralV1(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap
                );
            } else {
                _redeemOtToExactCollateralV1(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap, dataGuess
                );
            }
        }
    }

    function _swapMarketV2(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory paramsSwap,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        IntegratorParams memory paramsIntegrator
    ) internal {
        if (paramsSwap.amount == 0) revert Errors.RouterInvalidSwapAmount();
        if (paramsIntegrator.integrator == address(0) && paramsIntegrator.integratorFeeBps > 0) {
            revert Errors.RouterInvalidIntegrator();
            // note: integrator params after guard clause is non-zero address OR zero fee
        }
        if (paramsIntegrator.integratorFeeBps > MAXIMUM_INTEGRATOR_FEE_BPS) revert Errors.RouterIntegratorFeeTooHigh();

        if (paramsSwap.isMint) {
            if (paramsSwap.isExactIn) {
                _mintExactCollateralToOtV2(
                    market,
                    receiver,
                    tokenId,
                    paramsSwap.amount,
                    paramsSwap.minOutOrMaxIn,
                    dataSwap,
                    dataGuess,
                    paramsIntegrator
                );
            } else {
                _mintCollateralToExactOtV2(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap, paramsIntegrator
                );
            }
        } else {
            if (paramsSwap.isExactIn) {
                _redeemExactOtToCollateralV2(
                    market, receiver, tokenId, paramsSwap.amount, paramsSwap.minOutOrMaxIn, dataSwap, paramsIntegrator
                );
            } else {
                _redeemOtToExactCollateralV2(
                    market,
                    receiver,
                    tokenId,
                    paramsSwap.amount,
                    paramsSwap.minOutOrMaxIn,
                    dataSwap,
                    dataGuess,
                    paramsIntegrator
                );
            }
        }
    }

    function _mintCollateralToExactOtV1(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otOutExact,
        uint256 collateralInMax,
        bytes calldata dataSwap
    ) internal {
        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();

        (uint256 collateralIn,) = _calMintCost(params.curve, market, tokenId, otOutExact, dataSwap);
        if (collateralIn > collateralInMax) revert Errors.RouterSlippage();

        _transferIn(params.collateral, params.parentTokenId, msg.sender, collateralIn);
        _forceApprove(params.collateral, params.parentTokenId, market, collateralIn);

        uint256 collateralInActual =
            IFTMarket(market).mintCollateralToExactOt(receiver, tokenId, otOutExact, dataSwap, "");
        if (collateralInActual != collateralIn) revert Errors.RouterDbCViolated();
    }

    function _mintExactCollateralToOtV1(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralInExact,
        uint256 otOutMin,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) internal {
        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();

        (uint256 otOut, uint256 collateralIn) =
            IFTCurve(params.curve).calOtDeltaByMintCost(market, tokenId, collateralInExact, dataGuess);
        if (otOut < otOutMin) revert Errors.RouterSlippage();

        _transferIn(params.collateral, params.parentTokenId, msg.sender, collateralIn);
        _forceApprove(params.collateral, params.parentTokenId, market, collateralIn);
        uint256 collateralInActual = IFTMarket(market).mintCollateralToExactOt(receiver, tokenId, otOut, dataSwap, "");
        if (collateralInActual != collateralIn) revert Errors.RouterDbCViolated();
    }

    function _redeemExactOtToCollateralV1(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otInExact,
        uint256 collateralOutMin,
        bytes calldata dataSwap
    ) internal {
        _transferIn(market, tokenId, msg.sender, otInExact);

        uint256 collateralOut = IFTMarket(market).redeemExactOtToCollateral(receiver, tokenId, otInExact, dataSwap);
        if (collateralOut < collateralOutMin) revert Errors.RouterSlippage();
    }

    function _redeemOtToExactCollateralV1(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralOutExact,
        uint256 otInMax,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) internal {
        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();

        (uint256 otIn, uint256 collateralOut) =
            IFTCurve(params.curve).calOtDeltaByRedeemValue(market, tokenId, collateralOutExact, dataGuess);
        if (otIn > otInMax) revert Errors.RouterSlippage();

        _transferIn(market, tokenId, msg.sender, otIn);
        uint256 collateralOutActual = IFTMarket(market).redeemExactOtToCollateral(receiver, tokenId, otIn, dataSwap);
        if (collateralOutActual != collateralOut) revert Errors.RouterDbCViolated();
    }

    function _mintCollateralToExactOtV2(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otOutExact,
        uint256 collateralInMax,
        bytes calldata dataSwap,
        IntegratorParams memory paramsIntegrator
    ) internal {
        MintPointer memory ptr;

        {
            MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
            ptr.collateral = params.collateral;
            ptr.parentTokenId = params.parentTokenId;

            (ptr.collateralIn,) = _calMintCost(params.curve, market, tokenId, otOutExact, dataSwap);
        }

        ptr.collateralToIntegrator = Integrator.calIntegratorFee(ptr.collateralIn, paramsIntegrator.integratorFeeBps);
        ptr.collateralInTotal = ptr.collateralIn + ptr.collateralToIntegrator;
        if (ptr.collateralInTotal > collateralInMax) revert Errors.RouterSlippage();

        _transferIn(ptr.collateral, ptr.parentTokenId, msg.sender, ptr.collateralInTotal);
        _transferOut(ptr.collateral, ptr.parentTokenId, paramsIntegrator.integrator, ptr.collateralToIntegrator);

        _forceApprove(ptr.collateral, ptr.parentTokenId, market, ptr.collateralIn);
        uint256 collateralInActual =
            IFTMarketV2(market).mintCollateralToExactOt(receiver, tokenId, otOutExact, dataSwap);
        if (collateralInActual != ptr.collateralIn) revert Errors.RouterDbCViolated();

        // note: always emit to track attribution
        emit MintIntegratorFee(
            msg.sender, paramsIntegrator.integrator, market, tokenId, ptr.collateralInTotal, ptr.collateralToIntegrator
        );
    }

    function _mintExactCollateralToOtV2(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralInExact,
        uint256 otOutMin,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        IntegratorParams memory paramsIntegrator
    ) internal {
        MintPointer memory ptr;

        {
            MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
            ptr.collateral = params.collateral;
            ptr.parentTokenId = params.parentTokenId;

            (ptr.otOut, ptr.collateralIn) = IFTCurve(params.curve)
                .calOtDeltaByMintCost(
                    market,
                    tokenId,
                    Integrator.subIntegratorFee(collateralInExact, paramsIntegrator.integratorFeeBps), // note: reserve integrator fees
                    dataGuess
                );
            if (ptr.otOut < otOutMin) revert Errors.RouterSlippage();
        }

        // note: recalculate because collateralIn != collateralInExact (curve may round down)
        ptr.collateralToIntegrator = Integrator.calIntegratorFee(ptr.collateralIn, paramsIntegrator.integratorFeeBps);
        ptr.collateralInTotal = ptr.collateralIn + ptr.collateralToIntegrator;
        if (ptr.collateralInTotal > collateralInExact) revert Errors.RouterSlippage();

        _transferIn(ptr.collateral, ptr.parentTokenId, msg.sender, ptr.collateralInTotal);
        _transferOut(ptr.collateral, ptr.parentTokenId, paramsIntegrator.integrator, ptr.collateralToIntegrator);

        _forceApprove(ptr.collateral, ptr.parentTokenId, market, ptr.collateralIn);
        uint256 collateralInActual = IFTMarketV2(market).mintCollateralToExactOt(receiver, tokenId, ptr.otOut, dataSwap);
        if (collateralInActual != ptr.collateralIn) revert Errors.RouterDbCViolated();

        // note: always emit to track attribution
        emit MintIntegratorFee(
            msg.sender, paramsIntegrator.integrator, market, tokenId, ptr.collateralInTotal, ptr.collateralToIntegrator
        );
    }

    function _redeemExactOtToCollateralV2(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otInExact,
        uint256 collateralOutMin,
        bytes calldata dataSwap,
        IntegratorParams memory paramsIntegrator
    ) internal {
        RedeemPointer memory ptr;

        {
            MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
            ptr.collateral = params.collateral;
            ptr.parentTokenId = params.parentTokenId;
        }

        _transferIn(market, tokenId, msg.sender, otInExact);

        ptr.collateralOut = IFTMarketV2(market).redeemExactOtToCollateral(address(this), tokenId, otInExact, dataSwap);
        ptr.collateralToIntegrator = Integrator.calIntegratorFee(ptr.collateralOut, paramsIntegrator.integratorFeeBps);
        ptr.collateralToUser = ptr.collateralOut - ptr.collateralToIntegrator;
        if (ptr.collateralToUser < collateralOutMin) revert Errors.RouterSlippage();

        _transferOut(ptr.collateral, ptr.parentTokenId, receiver, ptr.collateralToUser);
        _transferOut(ptr.collateral, ptr.parentTokenId, paramsIntegrator.integrator, ptr.collateralToIntegrator);

        // note: always emit to track attribution
        emit RedeemIntegratorFee(
            msg.sender, paramsIntegrator.integrator, market, tokenId, ptr.collateralToUser, ptr.collateralToIntegrator
        );
    }

    function _redeemOtToExactCollateralV2(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralOutExact,
        uint256 otInMax,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        IntegratorParams memory paramsIntegrator
    ) internal {
        RedeemPointer memory ptr;

        {
            MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
            ptr.collateral = params.collateral;
            ptr.parentTokenId = params.parentTokenId;

            (ptr.otIn, ptr.collateralOut) = IFTCurve(params.curve)
                .calOtDeltaByRedeemValue(
                    market,
                    tokenId,
                    Integrator.includeIntegratorFee(collateralOutExact, paramsIntegrator.integratorFeeBps),
                    dataGuess
                );
            if (ptr.otIn > otInMax) revert Errors.RouterSlippage();
        }

        _transferIn(market, tokenId, msg.sender, ptr.otIn);

        uint256 collateralOutActual =
            IFTMarketV2(market).redeemExactOtToCollateral(address(this), tokenId, ptr.otIn, dataSwap);
        if (collateralOutActual != ptr.collateralOut) revert Errors.RouterDbCViolated();

        ptr.collateralToIntegrator = Integrator.calIntegratorFee(ptr.collateralOut, paramsIntegrator.integratorFeeBps);
        ptr.collateralToUser = ptr.collateralOut - ptr.collateralToIntegrator;

        _transferOut(ptr.collateral, ptr.parentTokenId, receiver, ptr.collateralToUser);
        _transferOut(ptr.collateral, ptr.parentTokenId, paramsIntegrator.integrator, ptr.collateralToIntegrator);

        // note: always emit to track attribution
        emit RedeemIntegratorFee(
            msg.sender, paramsIntegrator.integrator, market, tokenId, ptr.collateralToUser, ptr.collateralToIntegrator
        );
    }

    /// @dev IFTCurve.calMintCostByOtDelta is a state modifying call, use this to avoid any issues
    function _calMintCost(address curve, address market, uint256 tokenId, uint256 otDelta, bytes calldata dataSwap)
        internal
        view
        returns (uint256 collateralFromUser, uint256 collateralToTreasury)
    {
        (bool success, bytes memory result) =
            curve.staticcall(abi.encodeCall(IFTCurve.calMintCostByOtDelta, (market, tokenId, otDelta, dataSwap)));
        if (!success) revert Errors.RouterStaticCallFailed();
        (collateralFromUser, collateralToTreasury) = abi.decode(result, (uint256, uint256));

        if (collateralFromUser == 0) revert Errors.MarketZeroCostBasis();
    }
}
