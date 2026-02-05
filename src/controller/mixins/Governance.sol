// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@ft/lib/Event.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/FTMath.sol";
import "@ft/src/interfaces/IRegistry.sol";

abstract contract Governance is IRegistry, HasFTEvents {
    uint256 public constant MAXIMUM_FEE_RATE = FTMath.FT_ONE / 100; // 1%

    address public treasury;
    mapping(address market => uint80 feeRate) internal feeRates;

    bool private paused;

    constructor(address _treasury) {
        if (_treasury == address(0)) revert Errors.RegistryInvalidTreasuryAddress();
        _setTreasury(_treasury);
    }

    function _setProtocolFeeRate(address market, uint80 feeRate) internal {
        if (feeRate > MAXIMUM_FEE_RATE) revert Errors.FactoryFeeRateExceedMaximumLimit();

        feeRates[market] = feeRate;
        emit SetFeeRate(market, feeRate);
    }

    function _setTreasury(address treasuryNew) internal {
        treasury = treasuryNew;
        emit SetTreasury(treasury);
    }

    // pausing stops trading on ALL markets
    function _pause() internal {
        paused = true;
        emit Paused(msg.sender);
    }

    function _unpause() internal {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function _getGovernance(address market) internal view returns (address _treasury, uint80 _feeRate) {
        _treasury = treasury;
        _feeRate = feeRates[market];
    }

    function isPaused() external view returns (bool) {
        return paused;
    }
}
