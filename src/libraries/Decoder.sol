// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {GuessParam} from "@ft/src/curves/CurveBase.sol";
import "@ft/lib/Errors.sol";
import {FTMath} from "@ft/lib/FTMath.sol";

library Decoder {
    uint256 private constant GUESS_PARAM_LENGTH = 96; // 3 * 32 bytes
    uint256 private constant DEFAULT_MAX_ITERATIONS = 50;
    uint256 private constant DEFAULT_EPSILON = 1e15; // 0.1%

    function encodeGuessParam(GuessParam memory guess) internal pure returns (bytes memory) {
        bytes memory data = new bytes(GUESS_PARAM_LENGTH);

        assembly {
            let dataPtr := add(data, 32) // Skip length prefix
            mstore(dataPtr, mload(add(guess, 64))) // guessOffchain
            mstore(add(dataPtr, 32), mload(add(guess, 96))) // maxIterations (4th field)
            mstore(add(dataPtr, 64), mload(add(guess, 128))) // eps (5th field)
        }

        return data;
    }

    // @dev returns a guess param with default params if no calldata exists, fails-fast if guess param doesn't make sense
    function decodeGuessParam(bytes calldata data) internal pure returns (GuessParam memory) {
        if (data.length == 0) {
            return GuessParam({
                otGuessMin: 0,
                otGuessMax: 0,
                otDeltaGuessOffchain: 0,
                maxIterations: DEFAULT_MAX_ITERATIONS,
                eps: DEFAULT_EPSILON
            });
        }
        if (data.length != GUESS_PARAM_LENGTH) revert Errors.GuessInvalidDataLength(data.length, GUESS_PARAM_LENGTH);

        GuessParam memory guess;
        assembly {
            let dataOffset := data.offset
            mstore(guess, 0) // guessMin = 0
            mstore(add(guess, 32), 0) // guessMax = 0
            mstore(add(guess, 64), calldataload(dataOffset)) // guessOffchain
            mstore(add(guess, 96), calldataload(add(dataOffset, 32))) // maxIterations
            mstore(add(guess, 128), calldataload(add(dataOffset, 64))) // eps
        }

        if (guess.eps > FTMath.FT_ONE) revert Errors.GuessEpsAboveMax();
        if (guess.maxIterations == 0) revert Errors.GuessMaxIterationsZero(); // max iteration of 0 should swap via OT

        return guess;
    }
}
