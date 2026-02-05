// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * Functions in FTMarket.sol can trigger an optional callback to the caller.
 * Callback interfaces are designed to work well with Morpho's Bundler3-Adaptor pattern while still being possible to use your own custom router.
 */
interface IFTMintCallback {
    /**
     * @notice Called when `mintCollateralToExactOt` is called in FTMarket
     * @param collateralIn amount of collateral required from msg.sender
     * @param otOut amount of OT given to receiver
     * @param dataCallback arbitrary data passed to `mintCollateralToExactOt`
     */
    function onMint(uint256 collateralIn, uint256 otOut, bytes calldata dataCallback) external;
}

