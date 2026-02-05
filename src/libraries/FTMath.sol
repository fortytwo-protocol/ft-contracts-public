// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@solady/utils/FixedPointMathLib.sol";

library FTMath {
    error SafeCastOverflow();
    error ClampIncorrectBounds();

    using FixedPointMathLib for uint256;

    // All multiplications and divisions are inlined. This means we need to:
    // divide by ONE when multiplying and multiply by ONE when dividing
    uint256 internal constant FT_ONE = 1e18; // 1 = 18 decimal places
    int256 internal constant FT_IONE = 1e18; // 1 = 18 decimal places
    uint8 internal constant FT_DECIMALS = 18; // keep it aligned with LogExpMath & FixedPointMathLib pls

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min128(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    function max128(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? a : b;
    }

    function isASmallerApproxB(uint256 a, uint256 b, uint256 eps) internal pure returns (bool) {
        return a <= b && a >= FixedPointMathLib.fullMulDivUp(b, FT_ONE - eps, FT_ONE);
    }

    function isAGreaterApproxB(uint256 a, uint256 b, uint256 eps) internal pure returns (bool) {
        return a >= b && a <= FixedPointMathLib.fullMulDiv(b, FT_ONE + eps, FT_ONE);
    }

    function clamp(uint256 x, uint256 lower, uint256 upper) internal pure returns (uint256 res) {
        if (lower > upper) revert ClampIncorrectBounds();
        res = x;
        if (x < lower) res = lower;
        else if (x > upper) res = upper;
    }

    /*///////////////////////////////////////////////////////////////
                                SAFE CASTS
    //////////////////////////////////////////////////////////////*/
    /// @dev forked from uniswap V4 but without custom reverts
    function toUint256(int256 x) internal pure returns (uint256 y) {
        if (x < 0) revert SafeCastOverflow();
        y = uint256(x);
    }

    /// @dev forked from uniswap V4 but without custom reverts
    function toUint128(uint256 x) internal pure returns (uint128 y) {
        y = uint128(x);
        if (x != y) revert SafeCastOverflow();
    }

    /// @dev forked from uniswap V4 but without custom reverts
    function toInt256(uint256 x) internal pure returns (int256 y) {
        y = int256(x);
        if (y < 0) revert SafeCastOverflow();
    }

    /// @dev this is just int256(uint128(x)), which will always pass. We use this so that the compiler will yell at us if we edit the type of x
    function to128Int256(uint128 x) internal pure returns (int256 y) {
        assembly ("memory-safe") {
            y := x
        }
    }
}
