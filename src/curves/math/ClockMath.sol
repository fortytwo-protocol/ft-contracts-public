// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {GuessParam, Guesser} from "@ft/src/curves/CurveBase.sol";

library ClockMint {
    using ClockMath for ClockMath.CurveParams;
    using FixedPointMathLib for uint256;
    using Guesser for GuessParam;

    function calSwap(
        ClockMath.CurveParams memory curve,
        uint256 feeRate,
        uint256 otSupply,
        uint256 otDelta,
        uint256 timePassed
    ) internal pure returns (uint256 collateralFromUser, uint256 collateralToTreasury) {
        // collateral to pool = cost
        // fee to treasury = cost * feeRate
        // user pays cost * (1 + feeRate)
        if (otDelta == 0) revert Errors.MarketSwapAmountCannotBeZero();

        uint256 otFrom = otSupply;
        uint256 otTo = otFrom + otDelta;
        uint256 collateralFrom = curve.calCost(otFrom, timePassed);
        uint256 collateralTo = curve.calCostUp(otTo, timePassed);

        // GOAL: maximize collateralFromUser => user pays highest estimated cost
        // NOTE: it cannot be -ve, a -ve area implies you get paid to buy outcomes
        uint256 collateralCost = collateralTo > collateralFrom ? collateralTo - collateralFrom : 1;

        // treasury takes additional %, user pays another extra for mints
        collateralToTreasury = collateralCost.fullMulDivUp(feeRate, FTMath.FT_ONE);
        collateralFromUser = collateralCost + collateralToTreasury;
    }

    function guessOtDelta(
        ClockMath.CurveParams memory curve,
        uint256 feeRate,
        GuessParam memory guess,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 timePassed
    )
        internal
        pure
        returns (
            uint256, /*otDeltaGuess*/
            uint256 /*collateralDeltaRequired*/
        )
    {
        // 1. use offchain guess override
        if (guess.otDeltaGuessOffchain != 0) {
            (uint256 collateralDelta,) = calSwap(curve, feeRate, otSupply, guess.otDeltaGuessOffchain, timePassed);
            if (FTMath.isASmallerApproxB(collateralDelta, collateralDeltaTarget, guess.eps)) {
                return (guess.otDeltaGuessOffchain, collateralDelta);
            }
        }

        uint256 collateralDeltaPostFees = collateralDeltaTarget.fullMulDiv(FTMath.FT_ONE, FTMath.FT_ONE + feeRate);
        uint256 otDelta = curve.solveRoot(collateralDeltaPostFees, otSupply, timePassed);
        if (otDelta == 0) return (0, 0);

        // 2. refine both bounds via discrete newton
        guess.otGuessMin = 0;
        guess.otGuessMax = 0;

        uint256 iter;
        for (iter = 0; iter < guess.maxIterations; ++iter) {
            (uint256 collateralDelta,) = ClockMint.calSwap(curve, feeRate, otSupply, otDelta, timePassed);

            // hit target by chance return early
            if (FTMath.isASmallerApproxB(collateralDelta, collateralDeltaTarget, guess.eps)) {
                return (otDelta, collateralDelta);
            }

            uint256 price = curve.calMarginalPrice(otSupply + otDelta, timePassed);
            if (price == 0) price = 1;

            if (collateralDelta > collateralDeltaTarget) {
                // set one bound (case: overguess)
                guess.otGuessMax = otDelta;

                if (guess.otGuessMin > 0) break; // refinement complete

                uint256 step = (collateralDelta - collateralDeltaTarget).fullMulDivUp(FTMath.FT_ONE, price);
                if (step == 0) step = 1;
                otDelta = otDelta > step ? otDelta - step : 0;

                if (otDelta == 0) return (0, 0); // unreachable
            } else {
                // set one bound (case: underguess)
                guess.otGuessMin = otDelta;
                if (guess.otGuessMax > 0) break; // both bounds found

                uint256 step = (collateralDeltaTarget - collateralDelta).fullMulDivUp(FTMath.FT_ONE, price);
                if (step == 0) step = 1;
                otDelta += step;
            }
        }
        if (iter >= guess.maxIterations) {
            revert Errors.GuessExceedMaxIterations(guess.maxIterations);
        }

        // 3. binary search with refined bounds
        uint256 collateralDeltaLast;
        for (iter = 0; iter < guess.maxIterations; ++iter) {
            otDelta = guess.calMid();
            (collateralDeltaLast,) = ClockMint.calSwap(curve, feeRate, otSupply, otDelta, timePassed);

            if (FTMath.isASmallerApproxB(collateralDeltaLast, collateralDeltaTarget, guess.eps)) {
                return (otDelta, collateralDeltaLast);
            }

            if (collateralDeltaLast <= collateralDeltaTarget) {
                if (otDelta == guess.otGuessMin) break;
                guess.otGuessMin = otDelta;
            } else {
                if (otDelta == guess.otGuessMax) break;
                guess.otGuessMax = otDelta;
            }
        }
        if (iter >= guess.maxIterations) {
            revert Errors.GuessExceedMaxIterations(guess.maxIterations);
        } else {
            // show no solution (clearer)
            revert Errors.GuessTargetUnreachable(collateralDeltaLast, collateralDeltaTarget);
        }
    }
}

library ClockMath {
    using FixedPointMathLib for uint256;
    using ClockMath for CurveParams;

    uint256 private constant HALF = FTMath.FT_ONE / 2; // 1/2

    /**
     * og cost(x) = T(t) * M * x^2/2 + c * x
     * cost(x) = T(t) * x^2
     * marginal_price(x) = T(t) * 2x
     * T(t) = tMin + (tMax - tMin) * t
     */
    struct CurveParams {
        uint256 start;
        uint256 timePremiumMin;
        uint256 timePremiumMax;
        uint256 kink;
    }

    function calCost(CurveParams memory self, uint256 otSupply, uint256 timePassed) internal pure returns (uint256) {
        // cost(x) = T(t) * x^2
        uint256 x = otSupply + self.start;
        uint256 timePremium = self.calTimePremium(timePassed);
        uint256 otSupplySquared = x.fullMulDiv(x, FTMath.FT_ONE);

        return timePremium.fullMulDiv(otSupplySquared, FTMath.FT_ONE);
    }

    function calCostUp(CurveParams memory self, uint256 otSupply, uint256 timePassed) internal pure returns (uint256) {
        // cost(x) = T(t) * x^2
        uint256 x = otSupply + self.start;
        uint256 timePremium = self.calTimePremiumUp(timePassed);
        uint256 otSupplySquared = x.fullMulDivUp(x, FTMath.FT_ONE);

        return timePremium.fullMulDivUp(otSupplySquared, FTMath.FT_ONE);
    }

    function calMarginalPrice(CurveParams memory self, uint256 otSupply, uint256 timePassed)
        internal
        pure
        returns (uint256)
    {
        // marginal_price(x) = d cost(x)/dx = T(t) * 2x
        uint256 x = otSupply + self.start;
        uint256 timePremium = self.calTimePremium(timePassed);

        return timePremium.fullMulDiv(x, HALF);
    }

    function isValid(CurveParams memory self) internal pure returns (bool) {
        return self.timePremiumMax >= self.timePremiumMin && self.kink <= FTMath.FT_ONE;
    }

    function calTimePremium(CurveParams memory self, uint256 timePassed) internal pure returns (uint256) {
        if (timePassed <= self.kink) {
            return self.timePremiumMin;
        } else {
            return self.timePremiumMin
                + (self.timePremiumMax - self.timePremiumMin)
                .fullMulDiv(timePassed - self.kink, FTMath.FT_ONE - self.kink);
        }
    }

    function calTimePremiumUp(CurveParams memory self, uint256 timePassed) internal pure returns (uint256) {
        if (timePassed <= self.kink) {
            return self.timePremiumMin;
        } else {
            return self.timePremiumMin
                + (self.timePremiumMax - self.timePremiumMin)
                .fullMulDivUp(timePassed - self.kink, FTMath.FT_ONE - self.kink);
        }
    }

    function solveRoot(CurveParams memory self, uint256 collateralDeltaPostFees, uint256 otSupply, uint256 timePassed)
        internal
        pure
        returns (uint256)
    {
        // solve positive root for expansion of cost(x+delta,t) - cost(x,t) = collateralDelta
        uint256 x = otSupply + self.start;
        uint256 xSquared = x.fullMulDiv(x, FTMath.FT_ONE);
        uint256 timePremium = self.calTimePremiumUp(timePassed);
        uint256 collateralDeltaDivTimePremium = collateralDeltaPostFees.fullMulDiv(FTMath.FT_ONE, timePremium);
        uint256 termSqrt = (xSquared + collateralDeltaDivTimePremium).sqrtWad();
        if (termSqrt > x) {
            return termSqrt - x;
        } else {
            return 0;
        }
    }
}
