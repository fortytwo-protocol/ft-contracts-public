// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {Errors} from "@ft/lib/Errors.sol";

library LDAMath {
    using FixedPointMathLib for uint256;

    uint256 private constant DYNAMIC_WINDOW_DENOM = 10; // 10%

    /**
     * phi(t) = 1 + phiDeltaMax*(T-t)/T
     * mint(x,t) = phi(t)*( cost(phi(t)*(x+delta)) - cost(phi(t)*x) )
     * marginal_price(x,t) = phi(t)^2 * d cost(phi(t)*x)/dx
     */
    struct LDAPremiumParams {
        uint256 phi;
        uint256 phiSquared;
    }

    function newPremiumParams(
        uint256 phiDeltaMax,
        uint256 windowFixed,
        uint256 timeStart,
        uint256 timeEnd,
        uint256 timeMint
    ) internal pure returns (LDAPremiumParams memory premium) {
        if (timeEnd < timeStart) revert Errors.CurveInvalidStartEnd();

        // note: guard clause above guarantees timeEnd >= timeStart
        uint256 duration = timeEnd - timeStart;
        uint256 windowDynamic = duration / DYNAMIC_WINDOW_DENOM;
        uint256 window = FTMath.min(windowDynamic, windowFixed);
        if (window == 0) return _premiumLess();

        uint256 elapsed = timeMint > timeStart ? timeMint - timeStart : 0;
        if (elapsed >= window) return _premiumLess();

        if (phiDeltaMax == 0) return _premiumLess();
        uint256 phi = FTMath.FT_ONE + phiDeltaMax.fullMulDivUp(window - elapsed, window);
        uint256 phiSquared = phi.fullMulDivUp(phi, FTMath.FT_ONE);

        premium = LDAPremiumParams({phi: phi, phiSquared: phiSquared});
    }

    function hasPremium(LDAPremiumParams memory self) internal pure returns (bool) {
        return self.phi > FTMath.FT_ONE;
    }

    function applyPremiumToSupply(LDAPremiumParams memory self, uint256 supply) internal pure returns (uint256) {
        return supply.fullMulDiv(self.phi, FTMath.FT_ONE);
    }

    function applyPremiumToSupplyUp(LDAPremiumParams memory self, uint256 supply) internal pure returns (uint256) {
        return supply.fullMulDivUp(self.phi, FTMath.FT_ONE);
    }

    function applyPremiumToCost(LDAPremiumParams memory self, uint256 collateralCost) internal pure returns (uint256) {
        return collateralCost.fullMulDivUp(self.phi, FTMath.FT_ONE);
    }

    function applyPremiumToPrice(LDAPremiumParams memory self, uint256 rawPrice) internal pure returns (uint256) {
        return rawPrice.fullMulDiv(self.phiSquared, FTMath.FT_ONE);
    }

    function _premiumLess() private pure returns (LDAPremiumParams memory) {
        return LDAPremiumParams({phi: FTMath.FT_ONE, phiSquared: FTMath.FT_ONE});
    }
}
