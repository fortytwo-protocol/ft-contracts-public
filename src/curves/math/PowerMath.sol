// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@solady/utils/FixedPointMathLib.sol";
import "@ft/lib/FTMath.sol";
import "@ft/lib/LogExpMath.sol";
import "@ft/lib/RedeemMath.sol";
import "@ft/lib/Errors.sol";
import "@ft/src/curves/CurveBase.sol";

function stepFromDiff(uint256 collateralDiff, uint256 price, uint256 tick) pure returns (uint256) {
    uint256 tickStep = FixedPointMathLib.fullMulDivUp(collateralDiff, FTMath.FT_ONE, price);
    tickStep = (tickStep + tick - 1) / tick;
    if (tickStep == 0) tickStep = 1;
    return tickStep;
}

library PowerMint {
    using PowerMath for PowerMath.CurveParams;
    using FixedPointMathLib for uint256;
    using Guesser for GuessParam;

    function calSwap(PowerMath.CurveParams memory curve, uint256 feeRate, uint256 otSupply, uint256 otDelta)
        internal
        pure
        returns (uint256 collateralFromUser, uint256 collateralToTreasury)
    {
        // collateral to pool = cost * (1-feeRate)
        // fee to treasury = cost * (feeRate)
        if (otDelta == 0) revert Errors.MarketSwapAmountCannotBeZero();

        uint256 otFrom = otSupply;
        uint256 otTo = otFrom + otDelta;
        uint256 collateralFrom = curve.calCost(otFrom);
        uint256 collateralTo = curve.calCostUp(otTo);

        // GOAL: maximize collateralFromUser => user pays highest estimated cost
        // NOTE: it cannot be -ve, a -ve area implies you get paid to buy outcomes
        uint256 collateralCost = collateralTo > collateralFrom ? collateralTo - collateralFrom : 1;

        // treasury takes additional %, user pays another extra for mints
        collateralToTreasury = collateralCost.fullMulDivUp(feeRate, FTMath.FT_ONE);
        collateralFromUser = collateralCost + collateralToTreasury;
    }

    /**
     * swap (exactIn) collateral -> ? ot
     *
     * @dev guess can be unreachable (especially with large ticks & small target) as 1 tick can exceed the target
     */
    function guessOtDelta(
        PowerMath.CurveParams memory curve,
        uint256 feeRate,
        GuessParam memory guess,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 tick
    )
        internal
        pure
        returns (
            uint256, /*otDeltaGuess*/
            uint256 /*collateralDeltaRequired*/
        )
    {
        // A LOT easier to guess by ticks => convert discontinuous search space {1000, 2000, 3000,...} to {1, 2, 3,...}
        // guess.otGuessMin = tickLower, guess.otGuessMax = tickUpper

        // 0. save current tick pointer for refining bounds
        uint256 tickCurr;
        guess.otGuessMin = 0;
        guess.otGuessMax = 0;

        // 1. set current tick pointer
        if (guess.otDeltaGuessOffchain != 0) {
            tickCurr = guess.otDeltaGuessOffchain / tick; // note: may not be multiplier of tick?
            if (tickCurr == 0) tickCurr = 1;
        } else {
            uint256 price = curve.calMarginalPrice(otSupply);
            if (price == 0) price = 1;
            tickCurr = collateralDeltaTarget.fullMulDiv(FTMath.FT_ONE, price) / tick;
            if (tickCurr == 0) tickCurr = 1;
        }

        // 2. refine both bounds via discrete newton & current tick pointer (must use ticks, else it degrades)
        uint256 iter;
        for (iter = 0; iter < guess.maxIterations; ++iter) {
            uint256 otDeltaGuessCurr = tickCurr * tick;
            (uint256 collateralDelta,) = PowerMint.calSwap(curve, feeRate, otSupply, otDeltaGuessCurr);

            // hit target by chance return early
            if (FTMath.isASmallerApproxB(collateralDelta, collateralDeltaTarget, guess.eps)) {
                return (otDeltaGuessCurr, collateralDelta);
            }

            uint256 price = curve.calMarginalPrice(otSupply + otDeltaGuessCurr);
            if (price == 0) price = 1;

            if (collateralDelta > collateralDeltaTarget) {
                // set one bound (case: overguess)
                guess.otGuessMax = tickCurr;

                // no solution: target collateral is less than 1 tick
                if (tickCurr == 1) {
                    revert Errors.GuessTargetUnreachable(collateralDelta, collateralDeltaTarget);
                }

                if (guess.otGuessMin > 0) break; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDelta - collateralDeltaTarget, price, tick);
                tickCurr = tickCurr > tickStep ? tickCurr - tickStep : 1;
            } else {
                // set one bound (case: underguess)
                guess.otGuessMin = tickCurr;
                if (guess.otGuessMax > 0) break; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDeltaTarget - collateralDelta, price, tick);
                tickCurr += tickStep;
            }
        }
        if (iter >= guess.maxIterations) {
            revert Errors.GuessExceedMaxInterpolationIterations(guess.maxIterations);
        }

        // 3. binary search with refined bounds
        uint256 collateralDeltaLast;
        for (iter = 0; iter < guess.maxIterations; ++iter) {
            uint256 tickGuess = guess.calMid();
            uint256 otDeltaGuessCurr = tickGuess * tick;
            (collateralDeltaLast,) = PowerMint.calSwap(curve, feeRate, otSupply, otDeltaGuessCurr);

            if (FTMath.isASmallerApproxB(collateralDeltaLast, collateralDeltaTarget, guess.eps)) {
                return (otDeltaGuessCurr, collateralDeltaLast);
            }

            if (collateralDeltaLast <= collateralDeltaTarget) {
                if (tickGuess == guess.otGuessMin) break;
                guess.otGuessMin = tickGuess;
            } else {
                if (tickGuess == guess.otGuessMax) break;
                guess.otGuessMax = tickGuess;
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

library PowerRedeem {
    using PowerMath for PowerMath.CurveParams;
    using FixedPointMathLib for uint256;
    using Guesser for GuessParam;

    struct GuessPointer {
        uint256 iter;
        uint256 tickMax;
        uint256 tickCurr;
        uint256 collateralDeltaLast;
    }

    function calSwap(
        PowerMath.CurveParams memory curve,
        RedeemMath.RedeemParams memory redeem,
        uint256 feeRate,
        uint256 otSupply,
        uint256 otDelta
    ) internal pure returns (uint256 collateralToUser, uint256 collateralToTreasury) {
        // collateral from pool = cost * (1-taxRate)
        // fee to treasury = cost * (1-taxRate) * (feeRate)
        if (otDelta == 0) revert Errors.MarketSwapAmountCannotBeZero();

        uint256 otFrom = otSupply;
        uint256 otTo = otFrom - otDelta;
        uint256 collateralFrom = curve.calCost(otFrom);
        uint256 collateralTo = curve.calCostUp(otTo);
        // NOTE: it cannot be -ve, a -ve area implies you pay to sell outcomes
        // GOAL: minimize collateralTotal => user receives lowest estimated value
        uint256 collateralTotal = 0;
        if (collateralFrom > collateralTo) {
            collateralTotal = collateralFrom - collateralTo;
        }

        uint256 taxRate = RedeemMath.calRedeemTaxRate(redeem, otFrom + curve.start, otDelta + curve.start);
        uint256 collateralFromPool = collateralTotal.fullMulDiv(FTMath.FT_ONE - taxRate, FTMath.FT_ONE);
        collateralToTreasury = collateralFromPool.fullMulDivUp(feeRate, FTMath.FT_ONE);
        collateralToUser = collateralFromPool - collateralToTreasury;
    }

    /**
     * swap ? ot -> (exactOut) collateral
     *
     * @dev guess can be unreachable (especially with large ticks):
     *      1. collateral amount is too small, thus 1 tick exceeds the target
     *      2. collateral amount is too large, thus entire redeeming ot supply exceeds the target
     * @dev redeem formula changes wrt to otDeltaGuess, leading to possible edge cases
     */
    function guessOtDelta(
        PowerMath.CurveParams memory curve,
        RedeemMath.RedeemParams memory redeem,
        uint256 feeRate,
        GuessParam memory guess,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 tick
    )
        internal
        pure
        returns (
            uint256, /*otDeltaGuess*/
            uint256 /*collateralDeltaReturned*/
        )
    {
        // A LOT easier to guess by ticks => convert discontinuous search space {1000, 2000, 3000,...} to {1, 2, 3,...}
        // guess.otGuessMin = tickLower, guess.otGuessMax = tickUpper

        // no solution: nothing to redeem
        if (otSupply < tick) {
            revert Errors.GuessTargetUnreachable(0, collateralDeltaTarget);
        }

        // 0. save current tick pointer for refining bounds
        GuessPointer memory ptr;
        ptr.tickCurr = 0;
        ptr.tickMax = otSupply / tick;
        guess.otGuessMin = 0;
        guess.otGuessMax = 0;

        // 1. set current tick pointer
        if (guess.otDeltaGuessOffchain != 0) {
            ptr.tickCurr = FTMath.clamp(guess.otDeltaGuessOffchain / tick, 1, ptr.tickMax); // note: may not be multiplier of tick?
        } else {
            uint256 price = curve.calMarginalPrice(otSupply);
            if (price == 0) price = 1;
            ptr.tickCurr = FTMath.clamp(collateralDeltaTarget.fullMulDiv(FTMath.FT_ONE, price) / tick, 1, ptr.tickMax);
        }

        // 2. refine both bounds via discrete newton & current tick pointer (must use ticks, else it degrades)
        for (ptr.iter = 0; ptr.iter < guess.maxIterations; ++ptr.iter) {
            uint256 otDeltaGuessCurr = ptr.tickCurr * tick;
            (uint256 collateralDelta,) = PowerRedeem.calSwap(curve, redeem, feeRate, otSupply, otDeltaGuessCurr);

            // hit target by chance return early
            if (FTMath.isASmallerApproxB(collateralDelta, collateralDeltaTarget, guess.eps)) {
                return (otDeltaGuessCurr, collateralDelta);
            }

            // otSupply >= otDeltaGuessCurr since clamped earlier
            uint256 price = curve.calMarginalPrice(otSupply - otDeltaGuessCurr); // note: not exactly the derivative when redeem
            if (price == 0) price = 1;

            if (collateralDelta > collateralDeltaTarget) {
                // set one bound (case: overguess)
                guess.otGuessMax = ptr.tickCurr;

                // no solution: target collateral is less than 1 tick
                if (ptr.tickCurr == 1) {
                    revert Errors.GuessTargetUnreachable(collateralDelta, collateralDeltaTarget);
                }

                if (guess.otGuessMin > 0) break; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDelta - collateralDeltaTarget, price, tick);
                ptr.tickCurr = ptr.tickCurr > tickStep ? ptr.tickCurr - tickStep : 1;
            } else {
                // set one bound (case: underguess)
                guess.otGuessMin = ptr.tickCurr;

                // no solution: target collateral is more than supply's tick
                if (ptr.tickCurr == ptr.tickMax) {
                    revert Errors.GuessTargetUnreachable(collateralDelta, collateralDeltaTarget);
                }

                if (guess.otGuessMax > 0) break; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDeltaTarget - collateralDelta, price, tick);
                ptr.tickCurr = FTMath.clamp(ptr.tickCurr + tickStep, 1, ptr.tickMax);
            }
        }
        if (ptr.iter >= guess.maxIterations) {
            revert Errors.GuessExceedMaxInterpolationIterations(guess.maxIterations);
        }

        // 3. binary search with refined bounds
        for (ptr.iter = 0; ptr.iter < guess.maxIterations; ++ptr.iter) {
            uint256 tickGuess = guess.calMid();
            uint256 otDeltaGuessCurr = tickGuess * tick;
            (ptr.collateralDeltaLast,) = PowerRedeem.calSwap(curve, redeem, feeRate, otSupply, otDeltaGuessCurr);

            if (FTMath.isASmallerApproxB(ptr.collateralDeltaLast, collateralDeltaTarget, guess.eps)) {
                return (otDeltaGuessCurr, ptr.collateralDeltaLast);
            }

            if (ptr.collateralDeltaLast <= collateralDeltaTarget) {
                if (tickGuess == guess.otGuessMin) break;
                guess.otGuessMin = tickGuess;
            } else {
                if (tickGuess == guess.otGuessMax) break;
                guess.otGuessMax = tickGuess;
            }
        }
        if (ptr.iter >= guess.maxIterations) {
            revert Errors.GuessExceedMaxIterations(guess.maxIterations);
        } else {
            // show no solution (clearer)
            revert Errors.GuessTargetUnreachable(ptr.collateralDeltaLast, collateralDeltaTarget);
        }
    }
}

library PowerMath {
    using LogExpMath for uint256;
    using FixedPointMathLib for uint256;
    using PowerMath for CurveParams;

    /**
     * cost(x) = x^(c1+1)/c2
     * marginal_price(x) = d cost(x)/dx = (c1+1)*x^c1/c2
     * forward_price(x) = cost(x+1) - cost(x)
     */
    struct CurveParams {
        uint256 c1;
        uint256 c2;
        uint256 start;
    }

    function calCost(CurveParams memory self, uint256 otSupply) internal pure returns (uint256) {
        // cost(x) = x^(c1+1)/c2
        uint256 numerator = (otSupply + self.start).pow(self.c1 + LogExpMath.UONE_18);
        return numerator.fullMulDiv(FTMath.FT_ONE, self.c2);
    }

    function calCostUp(CurveParams memory self, uint256 otSupply) internal pure returns (uint256) {
        // cost(x) = x^(c1+1)/c2
        uint256 numerator = (otSupply + self.start).pow(self.c1 + LogExpMath.UONE_18);
        return numerator.fullMulDivUp(FTMath.FT_ONE, self.c2);
    }

    function calMarginalPrice(CurveParams memory self, uint256 otSupply) internal pure returns (uint256) {
        // marginal_price(x) = d cost(x)/dx = (c1+1)*x^c1/c2
        uint256 xPowC1 = (otSupply + self.start).pow(self.c1);
        return (self.c1 + FTMath.FT_ONE).fullMulDiv(xPowC1, self.c2);
    }

    function isValid(CurveParams memory self) internal pure returns (bool) {
        uint256 costStart = self.calCost(0);
        uint256 price = self.calMarginalPrice(0);
        return (self.start >= FTMath.toUint256(LogExpMath.LN_36_UPPER_BOUND)) && (costStart != 0) && (price != 0);
    }
}
