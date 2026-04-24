// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {HasFTEvents} from "@ft/lib/Event.sol";

contract FTDisputeRegistry is ReentrancyGuardTransient, HasFTEvents {
    uint256 private constant MAX_DISPUTE_DATA_LENGTH = 30000;

    IRegistry public immutable controllerV1;
    IRegistry public immutable controllerV2;

    struct DisputeAncillaryDataUpdate {
        uint256 timestamp;
        uint256 answerProposed;
        bytes data;
    }

    mapping(bytes32 id => DisputeAncillaryDataUpdate[] updatesPerId) private updates; // keccak256(abi.encode(controller, questionId, owner))

    constructor(address _controllerV1, address _controllerV2) {
        require(_controllerV2 != address(0), "controllerV2 zero");
        require(_controllerV1 != address(0), "controllerV1 zero");
        controllerV2 = IRegistry(_controllerV2);
        controllerV1 = IRegistry(_controllerV1);
    }

    function postDispute(bytes32 questionId, bytes calldata update, uint256 answerProposed) external nonReentrant {
        require(update.length <= MAX_DISPUTE_DATA_LENGTH, Errors.RegistryExceedMaxAncillaryDataUpdateLength());

        address controller = _getValidatedController(questionId);
        require(IRegistry(controller).getOutcomeAnswer(questionId) != 0, Errors.DRegistryQuestionNotResolved());
        require(!IRegistry(controller).isFinalised(questionId), Errors.DRegistryQuestionAlreadyFinalised());

        bytes32 id = _getDisputeId(controller, questionId, msg.sender);
        updates[id].push(
            DisputeAncillaryDataUpdate({timestamp: block.timestamp, answerProposed: answerProposed, data: update})
        );
        emit DisputeAncillaryDataUpdated(questionId, msg.sender, answerProposed, update);
    }

    function getLatestDisputeAncillaryUpdate(bytes32 questionId, address owner)
        external
        view
        returns (DisputeAncillaryDataUpdate memory)
    {
        address controller = _tryGetValidatedController(questionId);
        if (controller == address(0)) return DisputeAncillaryDataUpdate({timestamp: 0, answerProposed: 0, data: ""});

        bytes32 id = _getDisputeId(controller, questionId, owner);
        DisputeAncillaryDataUpdate[] storage updatesOwner = updates[id];
        if (updatesOwner.length == 0) return DisputeAncillaryDataUpdate({timestamp: 0, answerProposed: 0, data: ""});

        return updatesOwner[updatesOwner.length - 1];
    }

    function getDisputeAncillaryUpdates(bytes32 questionId, address owner)
        external
        view
        returns (DisputeAncillaryDataUpdate[] memory)
    {
        address controller = _tryGetValidatedController(questionId);
        if (controller == address(0)) return new DisputeAncillaryDataUpdate[](0);

        bytes32 id = _getDisputeId(controller, questionId, owner);
        return updates[id];
    }

    function getDisputeAncillaryUpdatesPaginated(bytes32 questionId, address owner, uint256 offset, uint256 limit)
        external
        view
        returns (DisputeAncillaryDataUpdate[] memory page)
    {
        require(limit > 0, Errors.DRegistryLimitIsZero());

        address controller = _tryGetValidatedController(questionId);
        if (controller == address(0)) return new DisputeAncillaryDataUpdate[](0);

        bytes32 id = _getDisputeId(controller, questionId, owner);
        DisputeAncillaryDataUpdate[] storage updatesOwner = updates[id];
        uint256 total = updatesOwner.length;
        if (offset >= total) return new DisputeAncillaryDataUpdate[](0);

        uint256 from = offset;
        uint256 to = from + limit;
        if (to > total) to = total;
        uint256 len = to - from;

        page = new DisputeAncillaryDataUpdate[](len);
        for (uint256 i = 0; i < len; ++i) {
            page[i] = updatesOwner[from + i];
        }
    }

    /// @return controller address, controllerV1 for V1, controllerV2 for V2. Reverts if question does not exist.
    function _getValidatedController(bytes32 questionId) internal view returns (address) {
        address controller = _tryGetValidatedController(questionId);
        if (controller == address(0)) {
            revert Errors.DRegistryInvalidQuestion();
        } else {
            return controller;
        }
    }

    function _tryGetValidatedController(bytes32 questionId) internal view returns (address) {
        // note: it is theoretically possible but highly unlikely for questionId collision
        if (controllerV1.getNumOutcomes(questionId) > 0) return address(controllerV1);
        if (controllerV2.getNumOutcomes(questionId) > 0) return address(controllerV2);
        return address(0);
    }

    function _getDisputeId(address controller, bytes32 questionId, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(controller, questionId, owner));
    }
}
