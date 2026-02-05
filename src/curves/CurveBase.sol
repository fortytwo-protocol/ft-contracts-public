// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

struct GuessParam {
    uint256 otGuessMin;
    uint256 otGuessMax;
    uint256 otDeltaGuessOffchain;
    uint256 maxIterations;
    uint256 eps;
}

library Guesser {
    function calMid(GuessParam memory guess) internal pure returns (uint256) {
        return (guess.otGuessMin + guess.otGuessMax + 1) / 2;
    }
}
