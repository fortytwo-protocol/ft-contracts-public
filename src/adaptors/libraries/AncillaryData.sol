// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

// utf8-encoding helpers (toUtf8Bytes*, appendKeyValue*, constructPrefix) are vendored
// verbatim from UMA Protocol:
// https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/common/implementation/AncillaryData.sol
// License: AGPL-3.0-only — preserved as-is. Do NOT relicense.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV2} from "@ft/src/adaptors/interfaces/IOptimisticOracleV2.sol";

/// @notice Routes an UMA callback (ancillary-only) back to a (questionId, outcomeIndex).
struct QuestionOutcome {
    bytes32 questionId;
    uint8 outcomeIndex;
}

/// @notice Per-question state (timing, flags, outcome metadata, retry bitmap).
struct QuestionData {
    uint256 retried; // bitmap
    uint256 proposalBond;
    address rewardToken;
    uint96 timestamp;
    address creator;
    uint32 liveness;
    uint8 numOutcomes;
    // dynamic
    string title;
    bytes description;
}

library AncillaryData {
    /// @notice In-memory snapshot of the fixed `QuestionData` fields
    struct QuestionDataCache {
        uint96 timestamp;
        address rewardToken;
        uint256 proposalBond;
        uint32 liveness;
        string title;
        bytes description;
    }

    /// @notice Unique query identifier for the Optimistic Oracle (UMIP-107).
    bytes32 internal constant PRICE_IDENTIFIER = "YES_OR_NO_QUERY";

    /// @notice Maximum ancillary data length.
    uint256 internal constant MAX_ANCILLARY_DATA = 8139;

    // requestPrice + setEventBased + setCallbacks
    uint256 private constant BASE_REQUEST_PRICE_CALLS = 3;

    error AdaptorAncillaryTooLong();
    error AdaptorQuestionAlreadyRegistered();
    error AdaptorOutcomeCountOverflow();

    function encode(
        bytes32 questionId,
        uint256 outcomeIndex,
        string memory title,
        bytes memory description,
        string memory outcomeName,
        uint256 requeryNonce,
        address controller,
        address initializer
    ) public pure returns (bytes memory out) {
        out = abi.encodePacked(
            "q: title: ",
            title,
            ", description: ",
            description,
            ", outcome: ",
            outcomeName,
            ", res_data: p1: 0, p2: 1, p3: 0.5. p1 = \"",
            outcomeName,
            "\" did NOT occur, ",
            "p2 = \"",
            outcomeName,
            "\" occurred, p3 = unknown/50-50"
        );

        out = abi.encodePacked(
            out, ". Updates made at registry at 0x", toUtf8BytesAddress(controller), " should be considered."
        );

        out = appendKeyValueBytes32(out, "questionId", questionId);
        out = appendKeyValueUint(out, "outcomeIndex", outcomeIndex);
        out = appendKeyValueUint(out, "requeryNonce", requeryNonce);
        out = appendKeyValueAddress(out, "initializer", initializer);
    }

    /// @notice Builds the price-request multicall for outcomes `startIndex..startIndex+names.length` and registers each ancillary hash.
    function requestPrice(
        mapping(bytes32 => QuestionOutcome) storage question,
        QuestionData storage data,
        bytes32 questionId,
        address controller,
        string[] memory names,
        uint256 startIndex,
        uint256 nonce,
        uint256 reward
    ) public returns (bytes[] memory calls) {
        // outcome bound check
        if (startIndex + names.length > type(uint8).max) revert AdaptorOutcomeCountOverflow();

        // Cacheq QuestionData fields
        QuestionDataCache memory cache = _loadQuestion(data);

        calls = new bytes[](_callsPerOutcome(cache.proposalBond, cache.liveness) * names.length);

        uint256 offset;
        for (uint256 i = 0; i < names.length; ++i) {
            offset = _registerAndEncode(
                question, cache, calls, offset, questionId, controller, names[i], startIndex + i, nonce, reward
            );
        }
    }

    /// @dev Encodes one outcome's ancillary, registers its routing entry, and appends its request blobs.
    function _registerAndEncode(
        mapping(bytes32 => QuestionOutcome) storage question,
        QuestionDataCache memory cache,
        bytes[] memory calls,
        uint256 offset,
        bytes32 questionId,
        address controller,
        string memory name,
        uint256 outcomeIndex,
        uint256 nonce,
        uint256 reward
    ) private returns (uint256) {
        bytes memory ancillary = encode(
            questionId, outcomeIndex, cache.title, cache.description, name, nonce, controller, address(this)
        );

        if (ancillary.length > MAX_ANCILLARY_DATA) revert AdaptorAncillaryTooLong();
        bytes32 id = keccak256(ancillary);
        if (question[id].questionId != bytes32(0)) revert AdaptorQuestionAlreadyRegistered();
        question[id] = QuestionOutcome({questionId: questionId, outcomeIndex: uint8(outcomeIndex)});

        return _encodeRequestData(calls, offset, ancillary, cache, reward);
    }

    /// @notice Builds the batched `settleAndGetPrice` multicall over every outcome's current ancillary.
    function settlePrice(QuestionData storage data, bytes32 questionId, address controller, string[] memory names)
        public
        view
        returns (bytes[] memory calls)
    {
        uint256 numOutcomes = data.numOutcomes;
        QuestionDataCache memory cache = _loadQuestion(data);
        uint256 retried = data.retried;
        calls = new bytes[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            calls[i] = _encodeSettle(cache, retried, questionId, controller, names[i], i);
        }
    }

    /// @dev Builds one outcome's `settleAndGetPrice` blob.
    function _encodeSettle(
        QuestionDataCache memory cache,
        uint256 retried,
        bytes32 questionId,
        address controller,
        string memory name,
        uint256 outcomeIndex
    ) private view returns (bytes memory) {
        uint256 nonce = (retried >> outcomeIndex) & 1;
        bytes memory ancillary =
            encode(questionId, outcomeIndex, cache.title, cache.description, name, nonce, controller, address(this));
        return abi.encodeCall(IOptimisticOracleV2.settleAndGetPrice, (PRICE_IDENTIFIER, cache.timestamp, ancillary));
    }

    /// @notice True if the OO has a settled price for every outcome's current ancillary.
    function hasAllPrices(
        QuestionData storage data,
        bytes32 questionId,
        IOptimisticOracleV2 oracle,
        address controller,
        string[] memory names
    ) public view returns (bool) {
        QuestionDataCache memory cache = _loadQuestion(data);
        uint256 retried = data.retried;
        uint256 numOutcomes = data.numOutcomes;
        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 nonce = (retried >> i) & 1;
            bytes memory ancillary =
                encode(questionId, i, cache.title, cache.description, names[i], nonce, controller, address(this));
            if (!oracle.hasPrice(address(this), PRICE_IDENTIFIER, cache.timestamp, ancillary)) return false;
        }
        return true;
    }

    function _callsPerOutcome(uint256 proposalBond, uint32 liveness) internal pure returns (uint256) {
        return BASE_REQUEST_PRICE_CALLS + (proposalBond > 0 ? 1 : 0) + (liveness > 0 ? 1 : 0);
    }

    /// @dev Caching of the fixed QuestionData fields shared by the request and settle paths.
    function _loadQuestion(QuestionData storage data) private view returns (QuestionDataCache memory cache) {
        cache.timestamp = data.timestamp;
        cache.rewardToken = data.rewardToken;
        cache.proposalBond = data.proposalBond;
        cache.liveness = data.liveness;
        cache.title = data.title;
        cache.description = data.description;
    }

    function _encodeRequestData(
        bytes[] memory calls,
        uint256 offset,
        bytes memory ancillary,
        QuestionDataCache memory cache,
        uint256 reward
    ) private pure returns (uint256) {
        uint96 ts = cache.timestamp;
        calls[offset++] = abi.encodeCall(
            IOptimisticOracleV2.requestPrice, (PRICE_IDENTIFIER, ts, ancillary, IERC20(cache.rewardToken), reward)
        );
        calls[offset++] = abi.encodeCall(IOptimisticOracleV2.setEventBased, (PRICE_IDENTIFIER, ts, ancillary));
        calls[offset++] =
            abi.encodeCall(IOptimisticOracleV2.setCallbacks, (PRICE_IDENTIFIER, ts, ancillary, false, true, false));
        if (cache.proposalBond > 0) {
            calls[offset++] =
                abi.encodeCall(IOptimisticOracleV2.setBond, (PRICE_IDENTIFIER, ts, ancillary, cache.proposalBond));
        }
        if (cache.liveness > 0) {
            calls[offset++] = abi.encodeCall(
                IOptimisticOracleV2.setCustomLiveness, (PRICE_IDENTIFIER, ts, ancillary, cache.liveness)
            );
        }
        return offset;
    }

    // ─── UMA AncillaryData helpers (vendored) ───────────────────────────────

    function appendKeyValueBytes32(bytes memory currentAncillaryData, bytes memory key, bytes32 value)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory prefix = constructPrefix(currentAncillaryData, key);
        return abi.encodePacked(currentAncillaryData, prefix, toUtf8Bytes(value));
    }

    function appendKeyValueAddress(bytes memory currentAncillaryData, bytes memory key, address value)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory prefix = constructPrefix(currentAncillaryData, key);
        return abi.encodePacked(currentAncillaryData, prefix, toUtf8BytesAddress(value));
    }

    function appendKeyValueUint(bytes memory currentAncillaryData, bytes memory key, uint256 value)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory prefix = constructPrefix(currentAncillaryData, key);
        return abi.encodePacked(currentAncillaryData, prefix, toUtf8BytesUint(value));
    }

    function constructPrefix(bytes memory currentAncillaryData, bytes memory key) internal pure returns (bytes memory) {
        if (currentAncillaryData.length > 0) {
            return abi.encodePacked(",", key, ":");
        } else {
            return abi.encodePacked(key, ":");
        }
    }

    function toUtf8Bytes(bytes32 bytesIn) internal pure returns (bytes memory) {
        return abi.encodePacked(toUtf8Bytes32Bottom(bytesIn >> 128), toUtf8Bytes32Bottom(bytesIn));
    }

    function toUtf8BytesAddress(address x) internal pure returns (bytes memory) {
        return
            abi.encodePacked(toUtf8Bytes32Bottom(bytes32(bytes20(x)) >> 128), bytes8(toUtf8Bytes32Bottom(bytes20(x))));
    }

    function toUtf8BytesUint(uint256 x) internal pure returns (bytes memory) {
        if (x == 0) {
            return "0";
        }
        uint256 j = x;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (x != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(x - (x / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            x /= 10;
        }
        return bstr;
    }

    // Highly gas-optimized bytes32-to-hex from https://gitter.im/ethereum/solidity?at=5840d23416207f7b0ed08c9b
    function toUtf8Bytes32Bottom(bytes32 bytesIn) private pure returns (bytes32) {
        unchecked {
            uint256 x = uint256(bytesIn);

            // Nibble interleave
            x = x & 0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff;
            x = (x | (x * 2 ** 64)) & 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff;
            x = (x | (x * 2 ** 32)) & 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff;
            x = (x | (x * 2 ** 16)) & 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff;
            x = (x | (x * 2 ** 8)) & 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff;
            x = (x | (x * 2 ** 4)) & 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f;

            // Hex encode
            uint256 h = (x & 0x0808080808080808080808080808080808080808080808080808080808080808) / 8;
            uint256 i = (x & 0x0404040404040404040404040404040404040404040404040404040404040404) / 4;
            uint256 j = (x & 0x0202020202020202020202020202020202020202020202020202020202020202) / 2;
            x = x + (h & (i | j)) * 0x27 + 0x3030303030303030303030303030303030303030303030303030303030303030;

            return bytes32(x);
        }
    }
}
