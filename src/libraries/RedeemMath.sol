// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@solady/utils/FixedPointMathLib.sol";
import "@ft/lib/FTMath.sol";
import "@ft/lib/LogExpMath.sol";

library RedeemMath {
    struct RedeemParams {
        // time factor params
        uint256 timeFromStartToEnd;
        uint256 timeFromStartToRedeem;
        uint256 timeKink;
        uint256 timeExponent;
        // growth factor params
        uint256 growthC1;
        uint256 growthC2;
    }

    using FixedPointMathLib for uint256;
    using LogExpMath for uint256;
    using LogExpMath for int256;
    using RedeemMath for RedeemParams;
    using FTMath for *;

    uint256 public constant MINIMUM_TAX_RATE = FTMath.FT_ONE / 1_000; // 10 bip or 0.1%
    uint256 public constant MAXIMUM_TAX_RATE = FTMath.FT_ONE * 9 / 10; // 90%
    uint256 public constant MINIMUM_OT_PROPORTION = FTMath.FT_ONE / 100_000_000; // 1 bip of 1 bip

    uint256 private constant ONE_MILLION = 1e6 * FTMath.FT_ONE;
    uint256 private constant TEN_MILLION = 1e7 * FTMath.FT_ONE;

    uint256 private constant ONE_POINT_TWO_FIVE = FTMath.FT_ONE * 125 / 100;
    uint256 private constant ONE_POINT_FIVE = FTMath.FT_ONE * 15 / 10;

    function calGrowthFactor(RedeemParams memory self, uint256 otSupply, uint256 otDelta)
        internal
        pure
        returns (uint256)
    {
        // X = otDelta/otSupply
        // growthfactor = c1*e^(c2*X)
        uint256 otProportion = otDelta.fullMulDivUp(FTMath.FT_ONE, otSupply);
        if (otProportion < MINIMUM_OT_PROPORTION) {
            otProportion = MINIMUM_OT_PROPORTION;
        }
        int256 exponent = self.growthC2.fullMulDivUp(otProportion, FTMath.FT_ONE).toInt256();
        uint256 result = self.growthC1.fullMulDivUp(exponent.exp().toUint256(), FTMath.FT_ONE);

        return result;
    }

    function calSupplyFactor(uint256 otSupply) internal pure returns (uint256) {
        // supply factor is a piecewise function
        uint256 supplyFactor;
        if (otSupply <= ONE_MILLION) {
            supplyFactor = FTMath.FT_ONE;
        } else if (otSupply <= TEN_MILLION) {
            supplyFactor = ONE_POINT_TWO_FIVE;
        } else {
            supplyFactor = ONE_POINT_FIVE;
        }

        return supplyFactor;
    }

    function calTimeFactor(RedeemParams memory self) internal pure returns (uint256) {
        // timefactor = (1+max(0,t-kink))^growth, t=%time passed
        uint256 timePassed = self.timeFromStartToRedeem.fullMulDivUp(FTMath.FT_ONE, self.timeFromStartToEnd);
        uint256 baseScale = FTMath.FT_ONE;
        if (timePassed > self.timeKink) {
            baseScale += timePassed - self.timeKink;
        }
        uint256 result = baseScale.pow(self.timeExponent);
        return result;
    }

    function calRedeemTaxRate(RedeemParams memory self, uint256 otSupply, uint256 otDelta)
        internal
        pure
        returns (uint256)
    {
        //r = min(1,growthfactor*supplyfactor*timefactor)
        uint256 growthFactor = self.calGrowthFactor(otSupply, otDelta);
        uint256 supplyFactor = calSupplyFactor(otSupply);
        uint256 timeFactor = self.calTimeFactor();
        uint256 rate = growthFactor.fullMulDivUp(supplyFactor, FTMath.FT_ONE).fullMulDivUp(timeFactor, FTMath.FT_ONE);

        return FTMath.clamp(rate, MINIMUM_TAX_RATE, MAXIMUM_TAX_RATE);
    }

    function newRedeemParams(
        uint128 timestampStart,
        uint128 timestampEnd,
        uint128 timestampCurrent,
        uint256 timeKink,
        uint256 timeExponent,
        uint256 growthC1,
        uint256 growthC2
    ) internal pure returns (RedeemParams memory) {
        uint256 timeFromStartToEnd = timestampEnd - timestampStart;
        uint256 timeFromStartToRedeem = 0;
        if (timestampStart < timestampCurrent) {
            timeFromStartToRedeem = timestampCurrent - timestampStart;
        }

        return RedeemParams({
            timeFromStartToEnd: timeFromStartToEnd,
            timeFromStartToRedeem: timeFromStartToRedeem,
            timeKink: timeKink,
            timeExponent: timeExponent,
            growthC1: growthC1,
            growthC2: growthC2
        });
    }
}
