// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {LogExpMath} from "@ft/lib/LogExpMath.sol";
import {Errors} from "@ft/lib/Errors.sol";

/**
 * @notice Second version of RedeemMath
 * - Easier to fine-tune tax dynamics both pre-kink and post-kink
 * - Preserve the original fundamentals of redeems -> redeem tax still revolves around the kink
 * - Value of redeem tax is still primarily dependent on:
 *   1. time
 *   2. trade size
 */
library RedeemMathV2 {
    struct RedeemParams {
        uint256 timeFromStartToEnd;
        uint256 timeFromStartToRedeem;

        uint256 timeKinkStart;
        uint256 timeKinkEnd;

        uint256 rateBaseMin; // minimum rate BEFORE LS
        uint256 rateBaseMax; // maximum rate BEFORE LS

        uint256 remapExp;

        // liquidity-sensitivity - higher root increases effective slippage during redeems
        uint256 lsRoot;
    }

    using FixedPointMathLib for uint256;
    using LogExpMath for uint256;
    using LogExpMath for int256;
    using RedeemMathV2 for RedeemParams;
    using FTMath for *;

    uint256 public constant MINIMUM_TAX_RATE = FTMath.FT_ONE / 1_000; // 10 bip or 0.1%
    uint256 public constant MAXIMUM_TAX_RATE = FTMath.FT_ONE * 9 / 10; // 90%
    uint256 public constant MINIMUM_OT_PROPORTION = FTMath.FT_ONE / 100_000_000; // 1 bip of 1 bip

    /**
     * @notice base rate is dependent on time and starts to exponentially increase after kink's start
     * @notice when time passed (t) is between kink start and kink end, base rate exponentially remaps between min and max rate.
     * Else, base rate pre-kink start maps to min rate and post-kink end maps to max rate
     */
    function calBaseRate(RedeemParams memory self) internal pure returns (uint256) {
        // baseRate = {pre-start: rateMin, during: exp_remap(rateMin,rateMax,timePassed), post-end: rateMax}
        uint256 timePassed = self.timeFromStartToRedeem.fullMulDivUp(FTMath.FT_ONE, self.timeFromStartToEnd);
        if (timePassed <= self.timeKinkStart) {
            return self.rateBaseMin;
        } else if (timePassed >= self.timeKinkEnd) {
            return self.rateBaseMax;
        }

        uint256 kinkProgress =
            (timePassed - self.timeKinkStart).fullMulDivUp(FTMath.FT_ONE, self.timeKinkEnd - self.timeKinkStart);

        // remapExp should be variable - it is derived from rateBaseMax and rateBaseMin for exponential remap
        int256 exponent = self.remapExp.fullMulDivUp(kinkProgress, FTMath.FT_ONE).toInt256();
        uint256 result = self.rateBaseMin.fullMulDivUp(exponent.exp().toUint256(), FTMath.FT_ONE);

        return result;
    }

    function calLSMultiplier(RedeemParams memory self, uint256 otSupply, uint256 otDelta)
        internal
        pure
        returns (uint256)
    {
        // X = otDelta/otSupply
        // LS = e^(lsRoot*X)
        uint256 otProportion = otDelta.fullMulDivUp(FTMath.FT_ONE, otSupply);
        if (otProportion < MINIMUM_OT_PROPORTION) otProportion = MINIMUM_OT_PROPORTION;
        if (otProportion > FTMath.FT_ONE) otProportion = FTMath.FT_ONE;
        int256 exponent = self.lsRoot.fullMulDivUp(otProportion, FTMath.FT_ONE).toInt256();

        return exponent.exp().toUint256();
    }

    function calRedeemTaxRate(RedeemParams memory self, uint256 otSupply, uint256 otDelta)
        internal
        pure
        returns (uint256)
    {
        // r = clamp(baseRate * LS, min, max)
        uint256 rateBase = self.calBaseRate();
        uint256 multiplier = self.calLSMultiplier(otSupply, otDelta);
        uint256 rate = rateBase.fullMulDivUp(multiplier, FTMath.FT_ONE);

        return FTMath.clamp(rate, MINIMUM_TAX_RATE, MAXIMUM_TAX_RATE);
    }

    function newRedeemParams(
        uint128 timestampStart,
        uint128 timestampEnd,
        uint128 timestampCurrent,
        uint256 timeKinkStart,
        uint256 timeKinkEnd,
        uint256 rateBaseMin,
        uint256 rateBaseMax,
        uint256 lsRoot
    ) internal pure returns (RedeemParams memory) {
        if (timeKinkEnd <= timeKinkStart) revert Errors.CurveInvalidStartEnd();
        if (rateBaseMin == 0) revert Errors.CurveInvalidParams();
        if (rateBaseMax <= rateBaseMin) revert Errors.CurveInvalidParams();

        int256 lnMax = int256(rateBaseMax).ln();
        int256 lnMin = int256(rateBaseMin).ln();
        uint256 remapExp = (lnMax - lnMin).toUint256();

        uint256 timeFromStartToEnd;
        uint256 timeFromStartToRedeem;
        if (timestampEnd <= timestampStart) {
            timeFromStartToEnd = 1;
            timeFromStartToRedeem = 1;
        } else {
            timeFromStartToEnd = timestampEnd - timestampStart;
            if (timestampStart < timestampCurrent) {
                timeFromStartToRedeem = timestampCurrent - timestampStart;
                if (timeFromStartToRedeem > timeFromStartToEnd) {
                    timeFromStartToRedeem = timeFromStartToEnd; // clamp to 100% to avoid reverts
                }
            } // else timeFromStartToRedeem = 0
        }

        return RedeemParams({
            timeFromStartToEnd: timeFromStartToEnd,
            timeFromStartToRedeem: timeFromStartToRedeem,
            timeKinkStart: timeKinkStart,
            timeKinkEnd: timeKinkEnd,
            rateBaseMin: rateBaseMin,
            rateBaseMax: rateBaseMax,
            remapExp: remapExp,
            lsRoot: lsRoot
        });
    }
}
