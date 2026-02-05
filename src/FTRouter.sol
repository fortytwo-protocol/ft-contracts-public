// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@ft/lib/Errors.sol";
import "@ft/lib/Fedec.sol";
import {Call} from "@ft/src/router/Multicallbackable.sol";
import "@ft/src/router/ActionSimple.sol";
import "@ft/src/router/ActionFromInitiator.sol";
import {IFTMintCallback} from "@ft/src/interfaces/IFTCallback.sol";

/**
 * - Primarily exists to support frontend, features still exist to support non-frontend but simplicity in interface is prioritised over gas-efficiency for now
 * - Router is stateless inter-transactions, intra-transactions it holds the initiator address
 */
contract FTRouter is ActionSimple, ActionFromInitiator, IFTMintCallback {
    using Fedec for bytes;
    using Fedec for Call;

    constructor(address _controller) ActionSimple(_controller) {}

    /// @inheritdoc IFTMintCallback
    function onMint(
        uint256 collateralIn,
        uint256,
        /*otOut*/
        bytes calldata dataCallback
    )
        external
        onlyMarket(msg.sender)
    {
        (bytes4 selector,) = dataCallback.decodeRaw();
        if (selector == ActionFromInitiator.erc20TransferFromInitiator.selector) {
            (address token, address receiver) = dataCallback.decodeERC20TransferFromInitiator();

            Call[] memory calls = new Call[](1);
            calls[0].allowFailure = false;
            calls[0].writeERC20TransferFromInitiator(token, receiver, collateralIn);

            _multicall(calls);
        } else if (selector == ActionFromInitiator.transferFromInitiator.selector) {
            (address token, uint256 tokenId, address receiver) = dataCallback.decodeTransferFromInitiator();

            Call[] memory calls = new Call[](1);
            calls[0].allowFailure = false;
            calls[0].writeTransferFromInitiator(token, tokenId, receiver, collateralIn);

            _multicall(calls);
        } else {
            revert Errors.RouterUnsupportedSelector();
        }
    }

    // no onRedeem yet
    // no onClaim yet
}
