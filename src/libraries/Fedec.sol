// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Call, Multicallbackable} from "@ft/src/router/Multicallbackable.sol";
import "@ft/src/FTRouter.sol";
import "@ft/src/router/ActionFromInitiator.sol";
import {FTLensBV1} from "@ft/src/lens/FTLensBV1.sol";

/**
 * Fortytwo Encode & Decode library for FTRouter
 * 1. Encode: transform relevant data into bytes according to data format required
 * 2. Decode: transform bytes into relevant data according to data format required (above)
 * 3. Write: take input data and write into `Call` struct for execution
 *
 * Data format is determined purely by the router, the core contracts only passes data back to the caller (core contracts do not consume callback data)
 * If you found this and you're trying to understand how the router manages the transfer of callback data between router <-> core contracts, you are at the right spot
 */
library Fedec {
    uint256 private constant SELECTOR_BYTES_OFFSET = 4;

    function decodeRaw(bytes calldata dataCallback) internal pure returns (bytes4 selector, bytes calldata data) {
        selector = bytes4(dataCallback);
        data = dataCallback[SELECTOR_BYTES_OFFSET:];
    }

    // msg format: (address token, address receiver)
    function encodeERC20TransferFromInitiator(address token, address receiver) internal pure returns (bytes memory) {
        return abi.encodePacked(ActionFromInitiator.erc20TransferFromInitiator.selector, abi.encode(token, receiver));
    }

    // msg format: (address token, address receiver)
    function decodeERC20TransferFromInitiator(bytes calldata data)
        internal
        pure
        returns (address token, address receiver)
    {
        return abi.decode(data[SELECTOR_BYTES_OFFSET:], (address, address));
    }

    function writeERC20TransferFromInitiator(Call memory call, address token, address receiver, uint256 amount)
        internal
        pure
    {
        call.callData = abi.encodeWithSelector(
            ActionFromInitiator.erc20TransferFromInitiator.selector, token, receiver, amount
        );
    }

    // msg format: (address token, uint256 tokenId, address receiver)
    function encodeTransferFromInitiator(address token, uint256 tokenId, address receiver)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(ActionFromInitiator.transferFromInitiator.selector, abi.encode(token, tokenId, receiver));
    }

    // msg format: (address token, uint256 tokenId, address receiver)
    function decodeTransferFromInitiator(bytes calldata data)
        internal
        pure
        returns (address token, uint256 tokenId, address receiver)
    {
        return abi.decode(data[SELECTOR_BYTES_OFFSET:], (address, uint256, address));
    }

    function writeTransferFromInitiator(
        Call memory call,
        address token,
        uint256 tokenId,
        address receiver,
        uint256 amount
    ) internal pure {
        call.callData = abi.encodeWithSelector(
            ActionFromInitiator.transferFromInitiator.selector, token, tokenId, receiver, amount
        );
    }
}
