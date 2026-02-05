// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@ft/src/interfaces/IFTMarket.sol";
import "@ft/src/interfaces/IFTCurve.sol";
import "@ft/src/interfaces/IRegistry.sol";
import "@ft/lib/TokenHelper.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/Fedec.sol";
import "@ft/lib/Market.sol";
import {SwapParams} from "@ft/lib/Market.sol";
import {FTMarketController} from "@ft/src/controller/FTMarketController.sol";

/**
 * 6 simple actions:
 * 1. mint collateral -> (exact) OT
 * 2. mint (exact) collateral -> OT
 * 3. redeem (exact) OT -> collateral
 * 4. redeem OT -> (exact) collateral
 * 5. claim OT -> collateral
 * 6. max claim OT -> collateral
 *
 * simple actions are entire(aka self-contained), there's no expectation of calling back another action or being called from a callback
 */
contract ActionSimple is TokenHelper {
    bytes private constant EMPTY_BYTES = "";

    FTMarketController public immutable controller;

    modifier onlyMarket(address market) {
        require(controller.isMarket(market), Errors.RouterUnauthorized());
        _;
    }

    constructor(address _controller) {
        controller = FTMarketController(_controller);
    }

    /**
     * @notice Simplified version without path-dependent callbacks
     * @dev Please wrap all calls in a multicall (to load initiator)
     * @dev Swap action is built for the frontend. Please integrate with the idea of changing params values instead of re-creating your own routing.
     * Each field in SwapParams is meant to be managed by useState hooks.
     * @param params swap parameters, please manage them via STATE. DO NOT ROUTE THE FIELDS YOU WILL CREATE BUGS FOR YOURSELF, THIS FUNCTION ALREADY ROUTES
     * @param dataSwap bytes data to be consumed by IFTCurve of the market for calculating swap
     * @param dataGuess bytes data to be consumed by IFTCurve of the market for guessing swap amount (required for exact collateral)
     */
    function swapSimple(
        address market,
        address receiver,
        uint256 tokenId,
        SwapParams memory params,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) external onlyMarket(market) {
        if (params.isMint) {
            if (params.isExactIn) {
                _mintExactCollateralToOtSimple(
                    market, receiver, tokenId, params.amount, params.minOutOrMaxIn, dataSwap, dataGuess
                );
                return;
            } else {
                _mintCollateralToExactOtSimple(market, receiver, tokenId, params.amount, params.minOutOrMaxIn, dataSwap);
                return;
            }
        } else {
            if (params.isExactIn) {
                _redeemExactOtToCollateralSimple(
                    market, receiver, tokenId, params.amount, params.minOutOrMaxIn, dataSwap
                );
                return;
            } else {
                _redeemOtToExactCollateralSimple(
                    market, receiver, tokenId, params.amount, params.minOutOrMaxIn, dataSwap, dataGuess
                );
                return;
            }
        }
    }

    /**
     * @notice Simplified version without path-dependent callbacks
     * @dev Although direct calls work, the interface is subject to change without notice
     * @param tokenIds tokenIds of OT to burn
     * @param otToBurn amount of each OT to burn, order must match with tokenIds
     */
    function claimSimple(address market, address receiver, uint256[] memory tokenIds, uint256[] memory otToBurn)
        external
        onlyMarket(market)
        returns (uint256 payout)
    {
        if (tokenIds.length != otToBurn.length) revert Errors.RouterArrayLengthsMismatch();

        uint256 len = tokenIds.length;
        for (uint256 i = 0; i < len; ++i) {
            // note: in simple case, msg.sender already has OT
            _transferIn(market, tokenIds[i], msg.sender, otToBurn[i]);
        }

        payout = IFTMarket(market).claim(receiver, tokenIds, otToBurn);
    }

    /**
     * @notice Simplified version without path-dependent callbacks
     * @dev Although direct calls work, the interface is subject to change without notice
     */
    function claimAllSimple(address market, address receiver) external onlyMarket(market) returns (uint256 payout) {
        address registry = IFTMarket(market).registry();
        (/*treasury*/,/*feeRate*/, uint256 numOutcomes,/*timestampEnd*/, uint256 answer, bool isFinalised) =
            IRegistry(registry).getConfig(market);

        if (answer == 0 || !isFinalised) revert Errors.RouterNotClaimableYet();
        uint256 counter = 0;
        uint256[] memory tokenIds = new uint256[](numOutcomes);
        uint256[] memory otToBurn = new uint256[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            if (Market.isWinner(answer, tokenId)) {
                uint256 otBalance = IFTMarket(market).balanceOf(msg.sender, tokenId);
                tokenIds[counter] = tokenId;
                otToBurn[counter] = otBalance;
                _transferIn(market, tokenId, msg.sender, otBalance);
                counter++;
            }
        }

        // adjust array length to counter
        assembly ("memory-safe") {
            mstore(tokenIds, counter)
            mstore(otToBurn, counter)
        }

        payout = IFTMarket(market).claim(receiver, tokenIds, otToBurn);
    }

    function _mintCollateralToExactOtSimple(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otOutExact,
        uint256 collateralInMax,
        bytes calldata dataSwap
    ) internal returns (uint256 collateralIn, uint256 otOut) {
        otOut = otOutExact;

        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();
        collateralIn = _executeMintCollateralToExactOt(market, receiver, tokenId, otOutExact, dataSwap, params);

        if (collateralIn > collateralInMax) revert Errors.RouterSlippage();
    }

    function _mintExactCollateralToOtSimple(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralInExact,
        uint256 otOutMin,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) internal returns (uint256 collateralIn, uint256 otOut) {
        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();

        (otOut, collateralIn) =
            IFTCurve(params.curve).calOtDeltaByMintCost(market, tokenId, collateralInExact, dataGuess);
        if (otOut < otOutMin) revert Errors.RouterSlippage();

        uint256 collateralInActual = _executeMintCollateralToExactOt(market, receiver, tokenId, otOut, dataSwap, params);
        if (collateralInActual != collateralIn) revert Errors.RouterDbCViolated();
    }

    function _executeMintCollateralToExactOt(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otOut,
        bytes calldata dataSwap,
        MarketDeployParams memory params
    ) internal returns (uint256 collateralIn) {
        _forceApprove(params.collateral, params.parentTokenId, market, type(uint256).max);
        collateralIn = IFTMarket(market)
            .mintCollateralToExactOt(
                receiver,
                tokenId,
                otOut,
                dataSwap,
                params.parentTokenId == NULL_PARENT_ID
                    ? Fedec.encodeERC20TransferFromInitiator(params.collateral, address(this))
                    : Fedec.encodeTransferFromInitiator(params.collateral, params.parentTokenId, address(this))
            );
        _forceApprove(params.collateral, params.parentTokenId, market, 0);
    }

    function _redeemExactOtToCollateralSimple(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 otInExact,
        uint256 collateralOutMin,
        bytes calldata dataSwap
    ) internal returns (uint256 otIn, uint256 collateralOut) {
        otIn = otInExact;

        _transferIn(market, tokenId, msg.sender, otIn);

        collateralOut = IFTMarket(market).redeemExactOtToCollateral(receiver, tokenId, otIn, dataSwap);
        if (collateralOut < collateralOutMin) revert Errors.RouterSlippage();
    }

    function _redeemOtToExactCollateralSimple(
        address market,
        address receiver,
        uint256 tokenId,
        uint256 collateralOutExact,
        uint256 otInMax,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) internal returns (uint256 otIn, uint256 collateralOut) {
        MarketDeployParams memory params = IFTMarket(market).readMarketDeployParams();

        (otIn, collateralOut) =
            IFTCurve(params.curve).calOtDeltaByRedeemValue(market, tokenId, collateralOutExact, dataGuess);
        if (otIn > otInMax) revert Errors.RouterSlippage();

        _transferIn(market, tokenId, msg.sender, otIn);

        uint256 collateralOutActual = IFTMarket(market).redeemExactOtToCollateral(receiver, tokenId, otIn, dataSwap);
        if (collateralOutActual != collateralOut) revert Errors.RouterDbCViolated();
    }
}
