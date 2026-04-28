// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct SimulateCall {
    bytes data;
    address target;
}

library Reverter {
    error UnexpectedRevertBytes(bytes revertData);
    error UnsupportedSelector();
    error ExpectedRevert();
    error Result(bytes result);

    function isReverterResult(bytes memory raw) internal pure returns (bool) {
        return (raw.length >= 4 && bytes4(raw) == Result.selector);
    }

    /// @dev bubbles up raw bytes, note it should be checked for an error
    function revertRaw(bytes memory raw) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 32): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(raw, 32), mload(raw))
        }
    }

    function revertResult(bytes memory result) internal pure {
        bytes memory resultWithSelector = abi.encodeWithSelector(Result.selector, result);
        revertRaw(resultWithSelector);
    }

    /// @dev requires raw to be Result error bytes, extracts result from raw revert data
    function decodeRevert(bytes memory raw) internal pure returns (bytes memory result) {
        // Skip the 4-byte selector and decode the ABI-encoded bytes parameter
        bytes memory encoded;
        assembly ("memory-safe") {
            encoded := add(raw, 4)
            mstore(encoded, sub(mload(raw), 4))
        }
        result = abi.decode(encoded, (bytes));
    }
}
