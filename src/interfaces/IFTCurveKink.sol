// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IFTCurveWithKink {
    /**
     * @notice read kink inflection point of curve. Only works for curves that have a kink for the redeem tax formula
     * @return timeKink kink of curve, express as % in WAD. For example, 1e18 is 100%, 9e17 is 90%, 5e16 is 5%
     */
    function timeKink() external view returns (uint256 timeKink);
}
