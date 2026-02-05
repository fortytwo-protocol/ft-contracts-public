// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Multicallbackable} from "@ft/src/router/Multicallbackable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@ft/lib/TokenHelper.sol";

/**
 * @dev NOTE: all function calls that can "bypass" approvals or have an origin as input should be stored here
 */
contract ActionFromInitiator is Multicallbackable, TokenHelper {
    /**
     * @dev forked from Morpho's bundler3
     */
    function erc20TransferFromInitiator(address token, address receiver, uint256 amount) external {
        require(receiver != address(0), "transfer to zero address");

        address from = initiator;
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(from);
        require(amount != 0, "zero amount");

        SafeERC20.safeTransferFrom(IERC20(token), from, receiver, amount);
    }

    /**
     * @notice Generalised transfer from for ERC6909 & ERC20.
     * @dev If you're only dealing with ERC20s (e.g aggregator swap), then just use the ERC20 one to minimise function scope pls.
     */
    function transferFromInitiator(address token, uint256 tokenId, address receiver, uint256 amount) external {
        require(receiver != address(0), "transfer to zero address");

        address from = initiator;
        if (amount == type(uint256).max) amount = _balance(token, tokenId, from);
        require(amount != 0, "zero amount");

        _transferFrom(token, tokenId, from, receiver, amount);
    }
}
