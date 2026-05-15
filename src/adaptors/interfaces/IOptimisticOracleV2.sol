// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOptimisticOracleV2
 * @notice Minimal interface to UMA's Optimistic Oracle V2.
 */
interface IOptimisticOracleV2 {
    enum State {
        Invalid,
        Requested,
        Proposed,
        Expired,
        Disputed,
        Resolved,
        Settled
    }

    struct RequestSettings {
        bool eventBased;
        bool refundOnDispute;
        bool callbackOnPriceProposed;
        bool callbackOnPriceDisputed;
        bool callbackOnPriceSettled;
        uint256 bond;
        uint256 customLiveness;
    }

    struct Request {
        address proposer;
        address disputer;
        IERC20 currency;
        bool settled;
        RequestSettings requestSettings;
        int256 proposedPrice;
        int256 resolvedPrice;
        uint256 expirationTime;
        uint256 reward;
        uint256 finalFee;
    }

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 reward
    ) external returns (uint256 totalBond);

    function proposePriceFor(
        address proposer,
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        int256 proposedPrice
    ) external returns (uint256 totalBond);

    function disputePriceFor(
        address disputer,
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData
    ) external returns (uint256 totalBond);

    function settleAndGetPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        returns (int256);

    function setBond(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 bond)
        external
        returns (uint256 totalBond);

    function setCustomLiveness(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256 customLiveness
    ) external;

    function setEventBased(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external;

    function setCallbacks(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        bool callbackOnPriceProposed,
        bool callbackOnPriceDisputed,
        bool callbackOnPriceSettled
    ) external;

    function hasPrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (bool);

    function getState(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (State);

    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (Request memory);

    /// @dev multicall inherited by Managed Optimistic Oracle V2
    // https://github.com/UMAprotocol/managed-oracle/blob/master/src/common/implementation/MultiCaller.sol
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}
