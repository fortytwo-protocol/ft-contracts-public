// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HasFTEvents} from "@ft/lib/Event.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {
    ControllerStorage,
    GovernanceStorage,
    FeeRateOverride,
    CollateralConfig
} from "@ft/src/controllerv2/ControllerStorage.sol";

abstract contract Governance is Initializable, HasFTEvents {
    uint80 internal constant MAXIMUM_FEE_RATE = uint80(FTMath.FT_ONE * 2 / 10); // 20%

    function __Governance_init(address treasury_, uint80 feeRateDefault_) internal onlyInitializing {
        __Governance_init_unchained(treasury_, feeRateDefault_);
    }

    function __Governance_init_unchained(address treasury_, uint80 feeRateDefault_) internal onlyInitializing {
        _setTreasury(treasury_);
        _setFeeRateDefault(feeRateDefault_);
    }

    function _setTreasury(address treasury) internal {
        if (treasury == address(0) || treasury == address(this)) revert Errors.RegistryInvalidTreasuryAddress();

        GovernanceStorage storage $ = ControllerStorage.governance();
        $.treasury = treasury;

        emit SetTreasury(treasury);
    }

    function _setFeeRateDefault(uint80 feeRateNew) internal {
        if (feeRateNew > MAXIMUM_FEE_RATE) revert Errors.RegistryFeeRateTooHigh();

        GovernanceStorage storage $ = ControllerStorage.governance();
        $.feeRateDefault = feeRateNew;

        emit SetProtocolFeeRate(feeRateNew);
    }

    function _setFeeRateOverride(address market, uint80 feeRate, bool isOverride) internal {
        if (isOverride && feeRate > MAXIMUM_FEE_RATE) revert Errors.RegistryFeeRateTooHigh();

        GovernanceStorage storage $ = ControllerStorage.governance();
        FeeRateOverride storage feeRateOverride = $.marketToOverride[market];

        feeRateOverride.feeRate = isOverride ? feeRate : 0;
        feeRateOverride.isOverride = isOverride;

        emit SetProtocolFeeOverride(market, isOverride ? feeRate : 0, isOverride);
    }

    function _setWhitelistedCollateral(address collateral, bool whitelist, uint256 collateralSeedMin) internal {
        // note: collateralSeedMin of 0 disables the check (any non-zero seed is accepted),
        // but a non-trivial seed is still recommend to prevent deadlocks in the market

        GovernanceStorage storage $ = ControllerStorage.governance();
        CollateralConfig storage config = $.whitelistedCollaterals[collateral];
        if (whitelist) {
            config.isWhitelisted = whitelist;
            config.collateralSeedMin = collateralSeedMin;
        } else {
            config.isWhitelisted = whitelist;
            config.collateralSeedMin = 0; // reset
        }

        emit CollateralWhitelist(collateral, config.isWhitelisted, config.collateralSeedMin);
    }

    function _setWhitelistedCurve(address curve, bool whitelist) internal {
        if (curve == address(0)) revert Errors.RegistryInvalidCurve();

        GovernanceStorage storage $ = ControllerStorage.governance();
        $.whitelistedCurves[curve] = whitelist;
        emit CurveWhitelist(curve, whitelist);
    }

    function _pause() internal {
        GovernanceStorage storage $ = ControllerStorage.governance();
        $.paused = true;

        emit Paused(msg.sender);
    }

    function _unpause() internal {
        GovernanceStorage storage $ = ControllerStorage.governance();
        $.paused = false;

        emit Unpaused(msg.sender);
    }

    // TODO: cosndier pause for market creation and question creation only?

    function _getFeeRate(address market) internal view returns (uint80) {
        GovernanceStorage storage $ = ControllerStorage.governance();
        FeeRateOverride storage feeRateOverride = $.marketToOverride[market];

        if (feeRateOverride.isOverride) {
            return feeRateOverride.feeRate;
        } else {
            return $.feeRateDefault;
        }
    }
}
