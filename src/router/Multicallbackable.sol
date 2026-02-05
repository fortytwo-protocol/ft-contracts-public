// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

struct Call {
    bool allowFailure;
    bytes callData;
}

struct Result {
    bool success;
    bytes returnData;
}

/**
 * @notice Contract that enables a multicall while enabling callbacks that delegatecalls multiple methods on itself
 *
 * This implementation comes from Morpho's Bundler3, changes are:
 * - removed to address & value from `Call` struct (only self calls allowed, no gas token transfers allowed)
 * - router is a singleton that self delegates (remove 1 layer of trust) instead of calling external adaptors
 * - IFTCallback.sol is still compatible with Bundler3-Adaptor architecture so you can still use it provided an appropriate adaptor
 */
contract Multicallbackable {
    /// @notice The initiator of the multicall transaction.
    address public initiator;

    /// @notice Executes a sequence of calls.
    /// @dev Locks the initiator so that the sender can be identified by other contracts.
    /// @param calls The ordered array of calldata to execute.
    function multicall(Call[] calldata calls) external returns (Result[] memory returnDatas) {
        require(initiator == address(0), "already initiated");

        initiator = msg.sender;

        returnDatas = _multicall(calls);

        initiator = address(0);
    }

    function _multicall(Call[] memory calls) internal returns (Result[] memory returnDatas) {
        uint256 length = calls.length;
        returnDatas = new Result[](length);
        address self = address(this);

        for (uint256 i = 0; i < length; ++i) {
            Call memory call = calls[i];
            (bool success, bytes memory returnData) = self.delegatecall(call.callData);
            if (!success && !call.allowFailure) {
                lowLevelRevert(returnData);
            }
            returnDatas[i] = Result({success: success, returnData: returnData});
        }
    }

    /// @dev Bubbles up the revert reason / custom error encoded in `error`.
    /// @dev Assumes `error` is the return data of any kind of failing CALL to a contract.
    function lowLevelRevert(bytes memory error) internal pure {
        assembly ("memory-safe") {
            revert(add(32, error), mload(error))
        }
    }
}
