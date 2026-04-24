// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

struct QuestionParams {
    uint96 timestampEnd;
    string title;
    bytes ancillaryData;
    string imageUri;
    string[] outcomeNames;
    string[] outcomeImageUris;
}

struct MarketParams {
    uint256 parentTokenId;
    address collateral;
    address curve;
    uint96 timestampStart;
}

struct QuestionStateV2 {
    address creator; // immutable
    uint96 timestampEnd;

    address oracle; // immutable
    uint96 timestampFinalise;

    uint256 answer;

    uint96 timestampFlagExpiry;

    string title; // immutable
    string imageUri;
    string[] outcomeNames;
    string[] outcomeImageUris;
}

struct AncillaryDataUpdate {
    uint256 timestamp;
    bytes update;
}

struct OutcomeNameDeduplicator {
    mapping(string => bool) dedup;
}

struct FeeRateOverride {
    uint80 feeRate;
    bool isOverride;
}

struct CollateralConfig {
    uint256 collateralSeedMin;
    bool isWhitelisted;
}

/// @custom:storage-location erc7201:fortytwo.storage.Governance
struct GovernanceStorage {
    address treasury;
    uint80 feeRateDefault;
    bool paused;

    mapping(address market => FeeRateOverride feeRateOverride) marketToOverride;
    mapping(address collateral => CollateralConfig config) whitelistedCollaterals;
    mapping(address curve => bool allowed) whitelistedCurves;
}

/// @custom:storage-location erc7201:fortytwo.storage.Registry
struct RegistryStorage {
    EnumerableSet.AddressSet markets;

    mapping(bytes32 questionId => QuestionStateV2 state) questions;
    mapping(bytes32 questionId => OutcomeNameDeduplicator deduplicator) outcomeDeduplicators;

    mapping(bytes32 updateId => AncillaryDataUpdate[] updatesPerId) updates; // updateId = keccak256(questionId,owner)
}

library ControllerStorage {
    function governance() internal pure returns (GovernanceStorage storage $) {
        bytes32 slot = SlotDerivation.erc7201Slot("fortytwo.storage.Governance");
        assembly {
            $.slot := slot
        }
    }

    function registry() internal pure returns (RegistryStorage storage $) {
        bytes32 slot = SlotDerivation.erc7201Slot("fortytwo.storage.Registry");
        assembly {
            $.slot := slot
        }
    }
}
