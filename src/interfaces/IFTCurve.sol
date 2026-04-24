// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IFTCurve {
    /**
     * @notice calculate marginal price of an OT. Marginal price refers to the cost to buy an infinitesimal amount of OT. Term comes from Robin Hanson's paper on Market Scoring Rules(AMM)
     * @return price marginal price, scaled to decimals of collateral
     */
    function calMarginalPrice(address market, uint256 tokenId) external view returns (uint256 price);

    /**
     * @notice calculate cost of OT given OT to mint. Cost refers to the total amount of collateral required. Term comes from Robin Hanson's paper on Market Scoring Rules(AMM)
     * @return collateralFromUser amount of collateral required from user. note that part of it goes to treasury as fees
     * @return collateralToTreasury fee of trade, given to treasury
     * @dev may contain state-modifying calls, note the lack of `view` modifier
     */
    function calMintCostByOtDelta(address market, uint256 tokenId, uint256 otDelta, bytes calldata dataSwap)
        external
        returns (uint256 collateralFromUser, uint256 collateralToTreasury);

    /**
     * @notice calculate value of OT given OT to redeem. Value refers to the total amount of collateral the OT is worth. Term is similar, but not the same as cost.
     * @return collateralToUser amount of collateral given to user. note that amount is POST fees (fees are already deducted)
     * @return collateralToTreasury fee of trade, given to treasury
     * @dev may contain state-modifying calls, note the lack of `view` modifier
     */
    function calRedeemValueByOtDelta(address market, uint256 tokenId, uint256 otDelta, bytes calldata dataSwap)
        external
        returns (uint256 collateralToUser, uint256 collateralToTreasury);

    /**
     * @notice calculate cost of OTs given OTs to seed. Cost refers to the total amount of collateral required. Term comes from Robin Hanson's paper on Market Scoring Rules(AMM)
     * the curve is agnostic to whether fees are charged and if OTs are given back to the seeder or to treasury.
     * @notice this function is called only for seed. Non-seed transactions do not use this.
     * seeding is different from minting as it is used to initialise the market, thus it is crucial for:
     * - setting up an initial "rate" for multi-dimensional bonding curves (i.e LMSR, AMMs) whereby invariants affect each other
     * - bypassing user-facing special mechanics (i.e mint premiums)
     * - seed at a fixed price without quotations (i.e RFQ or an external oracle)
     * - creating a curve where no OTs are minted and only collateral is donated (use dataSwap with otDeltas of 0)
     * @return collateralsFromUser amount of collaterals required from user
     * @return collateralsToTreasury fee of seed, given to treasury
     * @dev the curve can still implement the exact same formulas as mints, and it is not required to offer a preferntial quote
     * @dev may contain state-modifying calls, note the lack of `view` modifier
     * @dev guessing from collaterals is not provided due to possibility of onchain reverts with multiple swaps
     */
    function calSeedCostByOtDeltas(
        address market,
        uint256[] calldata tokenIds,
        uint256[] calldata otDeltas,
        bytes calldata dataSwap
    ) external returns (uint256[] memory collateralsFromUser, uint256[] memory collateralsToTreasury);

    /**
     * @notice approximate amount of OT to mint given collateral to spend. Cost refers to the total amount of collateral required. Term comes from Robin Hanson's paper on Market Scoring Rules(AMM)
     * @return otDelta best approximated amount of OT to mint
     * @return collateralFromUser expected amount of collateral required from user, PLEASE read DbC below.
     * @dev Interface's Design by Contract(DbC) MUST be followed: Given no other factors between approx and actual swap,
     * collateralFromUser returned must match the collateralFromUser returned by `calMintCostByOtDelta` called during actual swap.
     */
    function calOtDeltaByMintCost(address market, uint256 tokenId, uint256 collateralDelta, bytes calldata dataGuess)
        external
        view
        returns (uint256 otDelta, uint256 collateralFromUser);

    /**
     * @notice approximate amount of OT to redeem given collateral to receive. Value refers to the total amount of collateral the OT is worth. Term is similar, but not the same as cost.
     * @return otDelta best approximated amount of OT to redem
     * @return collateralToUser expected amount of collateral given to user, PLEASE read DbC below.
     * @dev Interface's Design by Contract(DbC) MUST be followed: Given no other factors between approx and actual swap,
     * collateralToUser returned must match the collateralToUser returned by `calRedeemValueByOtDelta` called during actual swap.
     */
    function calOtDeltaByRedeemValue(address market, uint256 tokenId, uint256 collateralDelta, bytes calldata dataGuess)
        external
        view
        returns (uint256 otDelta, uint256 collateralToUser);

    /**
     * @notice Exposes the curve's underlying cost function
     * @notice Does not return in collateral decimal precision as this is market-agnostic, refer to the curve library for decimals
     * @dev You are STRONGLY recommended to rely on `cal` functions instead of rawdogging everything using `simCost`.
     */
    function simCost(uint256 otSupply) external view returns (uint256 cost);

    /**
     * @notice Exposes the curve's underlying marginal price function
     * @notice Does not return in collateral decimal precision as this is market-agnostic, refer to the curve library for decimals
     * @dev You are STRONGLY recommended to rely on `cal` functions instead of rawdogging everything using `simCost`.
     */
    function simMarginalPrice(uint256 otSupply) external view returns (uint256 price);

    /**
     * @notice Exposes the curve's underlying seed logic, so that it is possible to estimate costs without a market
     * @return collateralFromUserTotal total amount of collateral required, given in collateral decimals
     * @return collateralToTreasuryTotal total amount of fees to treasury, given in collateral decimals
     * @dev Interface's Design by Contract(DbC) MUST be followed: Given to other factors between simSeed and seed,
     * collateralFromUserTotal must be sum of collateralsFromUser in calSeedCostByOtDeltas. collateralToTreasuryTotal must be sum of collateralsToTreasury in calSeedCostByOtDeltas.
     */
    function simSeed(uint256[] calldata tokenIds, uint256[] calldata otDeltas, uint8 collateralDecimals, uint80 feeRate)
        external
        view
        returns (uint256 collateralFromUserTotal, uint256 collateralToTreasuryTotal);

    /**
     * @notice There are a lot of factors involved in the curve, so this is a rather inaccurate function that attempts to "approximately" value an OT.
     * Calling this when all other factors are not aligned results in an invalid number.
     * Additionally, even when called properly there is no meaning to the number other than for frontend displays.
     * @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
     * @return collateralFromUser collateral required from user when minting from otFrom, assuming all factors aligned
     * @return collateralToTreasury collateral given to treasury, assuming all factors aligned
     * @dev collateralFromUser + collateralToTreasury = total approximated value of the position-ish
     */
    function extrapolateMintForOffchainOnly(address market, uint256 tokenId, uint256 otFrom, uint256 otDelta)
        external
        view
        returns (uint256 collateralFromUser, uint256 collateralToTreasury);

    /**
     * @notice There are a lot of factors involved in the curve, so this is a rather inaccurate function that attempts to "approximately" value an OT.
     * Calling this when all other factors are not aligned results in an invalid number.
     * Additionally, even when called properly there is no meaning to the number other than for frontend displays.
     * @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
     * @return collateralToUser collateral given to user when redeeming from otFrom, assuming all factors aligned
     * @return collateralToTreasury collateral given to treasury, assuming all factors aligned
     * @dev collateralToUser + collateralToTreasury = total approximated value of the position-ish
     */
    function extrapolateRedeemForOffchainOnly(address market, uint256 tokenId, uint256 otFrom, uint256 otDelta)
        external
        view
        returns (uint256 collateralToUser, uint256 collateralToTreasury);
}
