// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC6909, IERC6909Metadata} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import "@ft/lib/Errors.sol";

abstract contract TokenHelper {
    using SafeERC20 for IERC20;

    uint256 internal constant NULL_PARENT_ID = 0;

    function _forceApprove(address collateralOrParentOt, uint256 parentTokenId, address spender, uint256 amount)
        internal
    {
        if (parentTokenId != NULL_PARENT_ID) {
            IERC6909(collateralOrParentOt).approve(spender, parentTokenId, amount);
            return;
        } else {
            return IERC20(collateralOrParentOt).forceApprove(spender, amount);
        }
    }

    function _transferIn(address collateralOrParentOt, uint256 parentTokenId, address from, uint256 amount) internal {
        if (amount == 0) return;

        if (parentTokenId != NULL_PARENT_ID) {
            _safeTransferFrom6909(collateralOrParentOt, from, address(this), parentTokenId, amount);
            return;
        } else {
            IERC20(collateralOrParentOt).safeTransferFrom(from, address(this), amount);
        }
    }

    function _transferOut(address collateralOrParentOt, uint256 parentTokenId, address to, uint256 amount) internal {
        if (amount == 0) return;

        if (parentTokenId != NULL_PARENT_ID) {
            return _safeTransfer6909(collateralOrParentOt, to, parentTokenId, amount);
        } else {
            return IERC20(collateralOrParentOt).safeTransfer(to, amount);
        }
    }

    function _transferFrom(
        address collateralOrParentOt,
        uint256 parentTokenId,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (parentTokenId != NULL_PARENT_ID) {
            return _safeTransferFrom6909(collateralOrParentOt, from, to, parentTokenId, amount);
        } else {
            return IERC20(collateralOrParentOt).safeTransferFrom(from, to, amount);
        }
    }

    function _balance(address collateralOrParentOt, uint256 parentTokenId, address owner)
        internal
        view
        returns (uint256)
    {
        if (parentTokenId != NULL_PARENT_ID) {
            return IERC6909(collateralOrParentOt).balanceOf(owner, parentTokenId);
        } else {
            return IERC20(collateralOrParentOt).balanceOf(owner);
        }
    }

    function _selfBalance(address collateralOrParentOt, uint256 parentTokenId) internal view returns (uint256) {
        if (parentTokenId != NULL_PARENT_ID) {
            return IERC6909(collateralOrParentOt).balanceOf(address(this), parentTokenId);
        } else {
            return IERC20(collateralOrParentOt).balanceOf(address(this));
        }
    }

    function _collateralDecimals(address collateralOrParentOt, uint256 parentTokenId) internal view returns (uint8) {
        if (parentTokenId != NULL_PARENT_ID) {
            return IERC6909Metadata(collateralOrParentOt).decimals(parentTokenId);
        } else {
            return IERC20Metadata(collateralOrParentOt).decimals();
        }
    }

    function _collateralName(address collateralOrParentOt, uint256 parentTokenId)
        internal
        view
        returns (string memory)
    {
        if (parentTokenId != NULL_PARENT_ID) {
            return IERC6909Metadata(collateralOrParentOt).name(parentTokenId);
        } else {
            return IERC20Metadata(collateralOrParentOt).name();
        }
    }

    function _collateralSymbol(address collateralOrParentOt, uint256 parentTokenId)
        internal
        view
        returns (string memory)
    {
        if (parentTokenId != NULL_PARENT_ID) {
            return IERC6909Metadata(collateralOrParentOt).symbol(parentTokenId);
        } else {
            return IERC20Metadata(collateralOrParentOt).symbol();
        }
    }

    function _safeTransfer6909(address parent, address to, uint256 id, uint256 amount) internal {
        (bool success, bytes memory data) = parent.call(abi.encodeCall(IERC6909.transfer, (to, id, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Safe6909Transfer failed");
    }

    function _safeTransferFrom6909(address parent, address from, address to, uint256 id, uint256 amount) internal {
        (bool success, bytes memory data) = parent.call(abi.encodeCall(IERC6909.transferFrom, (from, to, id, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Safe6909Transfer failed");
    }
}
