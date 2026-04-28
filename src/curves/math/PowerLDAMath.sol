// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {GuessParam, Guesser} from "@ft/src/curves/CurveBase.sol";
import {PowerMath, PowerMint, stepFromDiff} from "@ft/src/curves/math/PowerMath.sol";
import {LDAMath} from "@ft/src/curves/math/LDAMath.sol";

library PowerLDAMint {
    using PowerMath for PowerMath.CurveParams;
    using LDAMath for LDAMath.LDAPremiumParams;
    using FixedPointMathLib for uint256;
    using Guesser for GuessParam;

    struct GuessPointer {
        uint256 iter;
        uint256 tickCurr;
        uint256 collateralDeltaLast;
    }

    function calSwap(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
        uint256 feeRate,
        uint256 otSupply,
        uint256 otDelta
    ) internal pure returns (uint256 collateralFromUser, uint256 collateralToTreasury) {
        // mint(x,t) = phi(t)*( cost(phi(t)*(x+delta)) - cost(phi(t)*x) )
        if (!premium.hasPremium()) {
            return PowerMint.calSwap(curve, feeRate, otSupply, otDelta);
        }

        if (otDelta == 0) revert Errors.MarketSwapAmountCannotBeZero();

        uint256 otFromScaled = premium.applyPremiumToSupply(otSupply);
        uint256 otToScaled = premium.applyPremiumToSupplyUp(otSupply + otDelta);
        uint256 collateralFrom = curve.calCost(otFromScaled);
        uint256 collateralTo = curve.calCostUp(otToScaled);

        // GOAL: maximize collateralFromUser => user pays highest estimated cost
        // NOTE: it cannot be -ve, a -ve area implies you get paid to buy outcomes
        uint256 collateralCost = collateralTo > collateralFrom ? collateralTo - collateralFrom : 1;
        collateralCost = premium.applyPremiumToCost(collateralCost);

        // treasury takes additional %, user pays another extra for mints
        collateralToTreasury = collateralCost.fullMulDivUp(feeRate, FTMath.FT_ONE);
        collateralFromUser = collateralCost + collateralToTreasury;
    }

    function calMarginalPrice(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
        uint256 otSupply
    ) internal pure returns (uint256) {
        // marginal_price(x,t) = phi(t)^2 * d cost(phi(t)*x)/dx
        if (!premium.hasPremium()) {
            return curve.calMarginalPrice(otSupply);
        }

        uint256 scaledSupply = premium.applyPremiumToSupply(otSupply);
        uint256 rawPrice = curve.calMarginalPrice(scaledSupply);
        return premium.applyPremiumToPrice(rawPrice);
    }

    /**
     * swap (exactIn) collateral -> ? ot
     *
     * @dev guess can be unreachable (especially with large ticks & small target) as 1 tick can exceed the target
     */
    function guessOtDelta(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
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
        if (!premium.hasPremium()) {
            return PowerMint.guessOtDelta(curve, feeRate, guess, collateralDeltaTarget, otSupply, tick);
        }

        GuessPointer memory ptr;
        guess.otGuessMin = 0;
        guess.otGuessMax = 0;

        // 1. set current tick pointer
        ptr.tickCurr = _getTickPtr(curve, premium, guess, collateralDeltaTarget, otSupply, tick);

        // 2. refine both bounds via discrete newton & current tick pointer (must use ticks, else it degrades)
        bool isSolved = _refineNewton(curve, premium, feeRate, guess, ptr, collateralDeltaTarget, otSupply, tick);
        if (isSolved) {
            return (ptr.tickCurr * tick, ptr.collateralDeltaLast);
        }

        // 3. binary search with refined bounds
        return _binarySearch(curve, premium, feeRate, guess, ptr, collateralDeltaTarget, otSupply, tick);
    }

    function _getTickPtr(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
        GuessParam memory guess,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 tick
    ) private pure returns (uint256 tickCurr) {
        if (guess.otDeltaGuessOffchain != 0) {
            tickCurr = guess.otDeltaGuessOffchain / tick;
            if (tickCurr == 0) tickCurr = 1;
        } else {
            uint256 price = PowerLDAMint.calMarginalPrice(curve, premium, otSupply);
            if (price == 0) price = 1;
            tickCurr = collateralDeltaTarget.fullMulDiv(FTMath.FT_ONE, price) / tick;
            if (tickCurr == 0) tickCurr = 1;
        }
    }

    function _refineNewton(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
        uint256 feeRate,
        GuessParam memory guess,
        GuessPointer memory ptr,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 tick
    ) private pure returns (bool isSolved) {
        for (ptr.iter = 0; ptr.iter < guess.maxIterations; ++ptr.iter) {
            uint256 otDeltaGuessCurr = ptr.tickCurr * tick;
            (uint256 collateralDelta,) = PowerLDAMint.calSwap(curve, premium, feeRate, otSupply, otDeltaGuessCurr);

            // hit target by chance return early
            if (FTMath.isASmallerApproxB(collateralDelta, collateralDeltaTarget, guess.eps)) {
                ptr.collateralDeltaLast = collateralDelta;
                return true;
            }

            uint256 price = PowerLDAMint.calMarginalPrice(curve, premium, otSupply + otDeltaGuessCurr);
            if (price == 0) price = 1;

            if (collateralDelta > collateralDeltaTarget) {
                // set one bound (case: overguess)
                guess.otGuessMax = ptr.tickCurr;

                // no solution: target collateral is less than 1 tick
                if (ptr.tickCurr == 1) {
                    revert Errors.GuessTargetUnreachable(collateralDelta, collateralDeltaTarget);
                }
                if (guess.otGuessMin > 0) return false; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDelta - collateralDeltaTarget, price, tick);
                ptr.tickCurr = ptr.tickCurr > tickStep ? ptr.tickCurr - tickStep : 1;
            } else {
                // set one bound (case: underguess)
                guess.otGuessMin = ptr.tickCurr;
                if (guess.otGuessMax > 0) return false; // refinement complete

                uint256 tickStep = stepFromDiff(collateralDeltaTarget - collateralDelta, price, tick);
                ptr.tickCurr += tickStep;
            }
        }
        revert Errors.GuessExceedMaxInterpolationIterations(guess.maxIterations);
    }

    function _binarySearch(
        PowerMath.CurveParams memory curve,
        LDAMath.LDAPremiumParams memory premium,
        uint256 feeRate,
        GuessParam memory guess,
        GuessPointer memory ptr,
        uint256 collateralDeltaTarget,
        uint256 otSupply,
        uint256 tick
    ) private pure returns (uint256, uint256) {
        for (ptr.iter = 0; ptr.iter < guess.maxIterations; ++ptr.iter) {
            uint256 tickGuess = guess.calMid();
            uint256 otDeltaGuessCurr = tickGuess * tick;
            (ptr.collateralDeltaLast,) = calSwap(curve, premium, feeRate, otSupply, otDeltaGuessCurr);

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
