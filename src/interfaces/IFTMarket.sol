// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {MarketDeployParams, MarketState} from "@ft/lib/Market.sol";
import {IERC6909TokenSupply, IERC6909Metadata} from "@openzeppelin/contracts/interfaces/IERC6909.sol";

interface IFTMarket is IERC6909Metadata, IERC6909TokenSupply {
    function mintCollateralToExactOt(
        address receiver,
        uint256 tokenId,
        uint256 otDeltaOut,
        bytes calldata dataSwap,
        bytes calldata dataCallback
    ) external returns (uint256 collateralIn);

    function redeemExactOtToCollateral(address receiver, uint256 tokenId, uint256 otDeltaIn, bytes calldata dataSwap)
        external
        returns (uint256 collateralOut);

    function seed(uint256 tokenId, uint256 otSeed, bytes calldata dataSwap) external;

    function claim(address receiver, uint256[] memory tokenIds, uint256[] memory otToBurn)
        external
        returns (uint256 payout);

    function simPayout(uint256 answerSim, uint256 otUserWinning) external view returns (uint256 payout);

    function totalMarketCap() external view returns (uint256);

    function marketType() external view returns (string memory);

    function collateralDecimals() external view returns (uint8 decimal);

    function readState() external view returns (MarketState memory);

    function readMarketDeployParams() external view returns (MarketDeployParams memory);

    function registry() external view returns (address);

    function questionId() external view returns (bytes32);

    function timestampStart() external view returns (uint128);
}
