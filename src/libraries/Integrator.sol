// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {FTMath} from "@ft/lib/FTMath.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

library Integrator {
    using FixedPointMathLib for uint256;

    uint256 internal constant FULL_BPS = 10_000;

    function calIntegratorFee(uint256 amount, uint256 integratorFeeBps) internal pure returns (uint256) {
        if (integratorFeeBps == 0) return 0;
        return amount.fullMulDiv(integratorFeeBps, FULL_BPS);
    }

    /// @dev Add integrator fee to amount. this is not the reverse of subIntegratorFee(). collateralFromUser = curve cost + protocol fee + integrator fee
    function addIntegratorFee(uint256 amount, uint256 integratorFeeBps) internal pure returns (uint256) {
        return amount + calIntegratorFee(amount, integratorFeeBps);
    }

    /// @dev Subtract integrator fee. collateralToUser = curve return - protocol fee - integrator fee
    function subIntegratorFee(uint256 amount, uint256 integratorFeeBps) internal pure returns (uint256) {
        return amount - calIntegratorFee(amount, integratorFeeBps);
    }

    /// @dev Reverse of subIntegratorFee(), this is not addIntegratorFee().
    /// @dev subIntegratorFee & includeIntegratorFee is NOT symmetric (i.e if b = a.subIntegratorFee(), a != b.includeIntegratorFee())
    function includeIntegratorFee(uint256 amountPostFee, uint256 integratorFeeBps) internal pure returns (uint256) {
        if (integratorFeeBps == 0) return amountPostFee;
        return amountPostFee.fullMulDivUp(FULL_BPS, FULL_BPS - integratorFeeBps);
    }
}
