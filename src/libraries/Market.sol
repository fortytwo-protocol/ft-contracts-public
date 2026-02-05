// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@ft/lib/Errors.sol";
import "@solady/utils/FixedPointMathLib.sol";
import "@ft/lib/FTMath.sol";
import "@ft/lib/RedeemMath.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";

struct MarketDeployParams {
    address collateral;
    uint256 parentTokenId;
    bytes32 questionId;
    address curve;
    uint128 timestampStart;
}

struct SwapParams {
    bool isMint; // collateral -> outcome
    uint256 amount;
    bool isExactIn;
    uint256 minOutOrMaxIn; // exactIn = min output, exactOut = max input
}

struct MarketState {
    // immutable
    address market;
    IFTCurve curve;
    uint128 timestampStart;
    // mutable, market related
    uint256 totalMarketCap;
    // mutable, question related
    address treasury;
    uint256 numOutcomes;
    uint128 timestampEnd;
    uint256 answer;
    bool isFinalised;
}

library Market {
    using FixedPointMathLib for uint256;

    function isValidTokenId(uint256 tokenId) internal pure returns (bool) {
        // 0 is null token id
        if (tokenId == 0) return false;

        // power of 2
        if ((tokenId) & (tokenId - 1) != 0) {
            return false;
        }

        return true;
    }

    /**
     * @notice TokenId works in powers of 2 from 0th index.
     * While the brain works with counts, most things are however 0-th indexed
     * @dev You are STRONGLY recommended to use this to avoid off-by-index errors
     */
    function toTokenId(uint256 indexOutcomeFromZero) internal pure returns (uint256) {
        // 1st outcome -> 2**(1-1) = tokenId 1
        // 2nd outcome -> 2**(2-1) = tokenId 2
        // 3rd outcome -> 2**(3-1) = tokenId 4

        return 2 ** indexOutcomeFromZero;
    }

    /**
     * @notice Reverse of toTokenId
     * @dev Almost everything should be done in terms of token id, especially core logic to avoid off-by-index errors
     * Try not to convert ids back and forth
     */
    function fromTokenId(uint256 tokenId) internal pure returns (uint256) {
        // tokenId 1 -> log2(1) = index 0
        // tokenId 2 -> log2(2) = index 1
        // tokenId 4 -> log2(4) = index 2
        if (!isValidTokenId(tokenId)) revert Errors.MarketInvalidTokenId(tokenId);

        uint256 index = 0;
        uint256 temp = tokenId >> 1;
        while (temp > 0) {
            temp >>= 1;
            index++;
        }
        return index;
    }

    /**
     * **
     * @return winner boolean value indicating whether tokenId is a winning OT
     * @dev Check via bitwise & operator. Refer to truth table:
     * ┌───┬───┬─────┬─────┬─────┐
     * │ A │ B │ AND │ OR  │ XOR │
     * ├───┼───┼─────┼─────┼─────┤
     * │ 0 │ 0 │  0  │  0  │  0  │
     * │ 0 │ 1 │  0  │  1  │  1  │
     * │ 1 │ 0 │  0  │  1  │  1  │
     * │ 1 │ 1 │  1  │  1  │  0  │
     * └───┴───┴─────┴─────┴─────┘
     */
    function isWinner(uint256 answer, uint256 tokenId) internal pure returns (bool) {
        // answer: 0b101
        // tokenId 1: 0b001 -> 0b101 & 0b001 is a winner
        // tokenId 2: 0b010 -> 0b101 & 0b010 is NOT a winner
        // tokenId 4: 0b100 -> 0b101 & 0b100 is a winner

        return (answer & tokenId) != 0;
    }

    /**
     * @dev invariant must be followed: mint more => pay more & mint more => price higher
     */
    function mintCollateralToOt(MarketState memory self, uint256 tokenId, uint256 otDeltaOut, bytes memory data)
        internal
        returns (uint256 collateralDeltaIn, uint256 collateralToTreasury)
    {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (otDeltaOut == 0) revert Errors.MarketSwapAmountCannotBeZero();
        if (!isValidTokenId(tokenId) || tokenId > toTokenId(self.numOutcomes - 1)) {
            revert Errors.MarketInvalidTokenId(tokenId);
        }

        /// ------------------------------------------------------------
        /// MATH
        /// ------------------------------------------------------------
        (collateralDeltaIn, collateralToTreasury) =
            self.curve.calMintCostByOtDelta(self.market, tokenId, otDeltaOut, data);

        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (collateralDeltaIn == 0) revert Errors.MarketZeroCostBasis();
        if (collateralDeltaIn < collateralToTreasury) revert Errors.MarketNotWhole();

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.totalMarketCap += collateralDeltaIn - collateralToTreasury;
    }

    /**
     * @dev invariant must be followed: redeem more => price lower
     */
    function redeemOtToCollateral(MarketState memory self, uint256 tokenId, uint256 otDeltaIn, bytes memory data)
        internal
        returns (uint256 collateralToUser, uint256 collateralToTreasury)
    {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (otDeltaIn == 0) revert Errors.MarketSwapAmountCannotBeZero();
        if (!isValidTokenId(tokenId) || tokenId > toTokenId(self.numOutcomes - 1)) {
            revert Errors.MarketInvalidTokenId(tokenId);
        }

        /// ------------------------------------------------------------
        /// MATH
        /// ------------------------------------------------------------
        (collateralToUser, collateralToTreasury) =
            self.curve.calRedeemValueByOtDelta(self.market, tokenId, otDeltaIn, data);

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.totalMarketCap -= collateralToUser + collateralToTreasury;
    }

    function claim(
        MarketState memory self,
        uint256[] memory tokenIds,
        uint256[] memory otToBurn,
        uint256 otSupplyWinning
    ) internal pure returns (uint256 payout, uint256 excess, uint256 otUserWinning) {
        /// ------------------------------------------------------------
        /// CHECKS
        /// ------------------------------------------------------------
        if (tokenIds.length != otToBurn.length) revert Errors.MarketArrayLengthsMismatch();
        if (tokenIds.length == 0) revert Errors.MarketNoClaim();

        // very awkward edge case: somehow no one holds the winners -> send to treasury and think about how to redistribute
        if (otSupplyWinning == 0) {
            excess = self.totalMarketCap;
            self.totalMarketCap = 0;
            // payout = 0, otUserWinning = 0
            return (payout, excess, otUserWinning);
        }

        /// ------------------------------------------------------------
        /// MATH
        /// ------------------------------------------------------------
        uint256 len = tokenIds.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 otBurned = otToBurn[i];
            if (Market.isWinner(self.answer, tokenId)) {
                otUserWinning += otBurned;
            }
        }

        if (otSupplyWinning == otUserWinning) {
            payout = self.totalMarketCap;
        } else {
            payout = self.totalMarketCap.fullMulDiv(otUserWinning, otSupplyWinning);
        }
        // excess = 0 here

        /// ------------------------------------------------------------
        /// WRITE
        /// ------------------------------------------------------------
        self.totalMarketCap -= payout;
    }
}
