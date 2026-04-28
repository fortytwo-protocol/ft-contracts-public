// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@ft/src/interfaces/IFTCurve.sol";
import "@ft/src/interfaces/IRegistry.sol";
import "@ft/src/curves/math/PowerMath.sol";
import "@ft/lib/FTMath.sol";
import "@ft/lib/Errors.sol";
import "@ft/lib/Decoder.sol";
import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";

contract PowerCurve is IFTCurve {
    using PowerMath for PowerMath.CurveParams;
    using FixedPointMathLib for uint256;
    using FTMath for uint256;

    struct MarketState {
        RedeemMath.RedeemParams redeem;
        uint256 feeRate;
        uint256 otCurrent;
        uint256 tick;
    }

    uint256 public immutable c1;
    uint256 public immutable c2;
    uint256 public immutable start;
    uint256 public immutable timeKink;
    uint256 public immutable timeExponent;
    uint256 public immutable growthC1;
    uint256 public immutable growthC2;
    uint256 public immutable tick;

    constructor(
        uint256 _c1,
        uint256 _c2,
        uint256 _start,
        uint256 _timeKink,
        uint256 _timeExponent,
        uint256 _growthC1,
        uint256 _growthC2,
        uint256 _tick
    ) {
        c1 = _c1;
        c2 = _c2;
        start = _start;
        // NOTE: "free" shares creates weird math problems especially when redeeming, so start from a non-free point
        PowerMath.CurveParams memory curve = readCurve();
        if (!curve.isValid()) revert Errors.CurveInvalidCost(start);

        timeKink = _timeKink;
        timeExponent = _timeExponent;
        growthC1 = _growthC1;
        growthC2 = _growthC2;

        tick = _tick;
    }

    /// @inheritdoc IFTCurve
    function calMarginalPrice(address market, uint256 tokenId) external view returns (uint256 price) {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        price = curve.calMarginalPrice(state.otCurrent);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        price = price.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    function calMintCostByOtDelta(
        address market,
        uint256 tokenId,
        uint256 otDelta,
        bytes calldata /*data*/
    )
        external
        view
        returns (uint256 collateralFromUser, uint256 collateralToTreasury)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        if (otDelta % state.tick != 0) revert Errors.CurveOtDeltaNotOnTick(otDelta, state.tick);

        (collateralFromUser, collateralToTreasury) = PowerMint.calSwap(curve, state.feeRate, state.otCurrent, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    function calRedeemValueByOtDelta(
        address market,
        uint256 tokenId,
        uint256 otDelta,
        bytes calldata /*data*/
    )
        external
        view
        returns (uint256 collateralToUser, uint256 collateralToTreasury)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        if (otDelta % state.tick != 0) revert Errors.CurveOtDeltaNotOnTick(otDelta, state.tick);

        (collateralToUser, collateralToTreasury) =
            PowerRedeem.calSwap(curve, state.redeem, state.feeRate, state.otCurrent, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralToUser = collateralToUser.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE); // effective sell price is lower
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    function calSeedCostByOtDeltas(
        address market,
        uint256[] calldata tokenIds,
        uint256[] calldata otDeltas,
        bytes calldata /*dataSwap*/
    ) external view returns (uint256[] memory collateralsFromUser, uint256[] memory collateralsToTreasury) {
        if (tokenIds.length != otDeltas.length) revert Errors.MarketArrayLengthsMismatch();

        PowerMath.CurveParams memory curve = readCurve();

        uint256 len = tokenIds.length;
        collateralsFromUser = new uint256[](len);
        collateralsToTreasury = new uint256[](len);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        for (uint256 i = 0; i < len; ++i) {
            uint256 otDelta = otDeltas[i];
            if (otDelta == 0) continue;

            MarketState memory state = readMarketState(market, tokenIds[i]);

            (uint256 collateralFromUser, uint256 collateralToTreasury) =
                PowerMint.calSwap(curve, state.feeRate, state.otCurrent, otDelta);
            collateralsFromUser[i] = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
            collateralsToTreasury[i] = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
        }
    }

    /// @inheritdoc IFTCurve
    function calOtDeltaByMintCost(address market, uint256 tokenId, uint256 collateralDelta, bytes calldata data)
        external
        view
        returns (uint256 otDelta, uint256 collateralFromUser)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        GuessParam memory guess = Decoder.decodeGuessParam(data);
        if (guess.otDeltaGuessOffchain % state.tick != 0) {
            revert Errors.CurveOtDeltaNotOnTick(guess.otDeltaGuessOffchain, state.tick);
        }

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        uint256 collateralDeltaScaled = collateralDelta.fullMulDiv(FTMath.FT_ONE, 10 ** collateralDecimals);

        (otDelta, collateralFromUser) =
            PowerMint.guessOtDelta(curve, state.feeRate, guess, collateralDeltaScaled, state.otCurrent, state.tick);
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    function calOtDeltaByRedeemValue(address market, uint256 tokenId, uint256 collateralDelta, bytes calldata data)
        external
        view
        returns (uint256 otDelta, uint256 collateralToUser)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        GuessParam memory guess = Decoder.decodeGuessParam(data);
        if (guess.otDeltaGuessOffchain % state.tick != 0) {
            revert Errors.CurveOtDeltaNotOnTick(guess.otDeltaGuessOffchain, state.tick);
        }

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        uint256 collateralDeltaScaled = collateralDelta.fullMulDiv(FTMath.FT_ONE, 10 ** collateralDecimals);

        (otDelta, collateralToUser) = PowerRedeem.guessOtDelta(
            curve, state.redeem, state.feeRate, guess, collateralDeltaScaled, state.otCurrent, state.tick
        );
        collateralToUser = collateralToUser.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /**
     * @notice read immutable curve params
     */
    function readCurve() public view returns (PowerMath.CurveParams memory curve) {
        curve = PowerMath.CurveParams({c1: c1, c2: c2, start: start});
    }

    /**
     * @notice read state of market required for calculations
     */
    function readMarketState(address market, uint256 tokenId) public view returns (MarketState memory state) {
        address registry = IFTMarket(market).registry();
        (, uint256 feeRate,, uint128 timestampEnd,,) = IRegistry(registry).getConfig(market);

        uint256 otCurrent = IERC6909TokenSupply(market).totalSupply(tokenId);

        uint128 timestampStart = IFTMarket(market).timestampStart();
        RedeemMath.RedeemParams memory redeem = RedeemMath.newRedeemParams(
            timestampStart, timestampEnd, block.timestamp.toUint128(), timeKink, timeExponent, growthC1, growthC2
        );

        state = MarketState({redeem: redeem, feeRate: feeRate, otCurrent: otCurrent, tick: tick});
    }

    /// @inheritdoc IFTCurve
    function simCost(uint256 otSupply) external view returns (uint256 cost) {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calCost(otSupply);
    }

    /// @inheritdoc IFTCurve
    function simCost(
        address, /*market*/
        uint256, /*tokenId*/
        uint256 otSupply
    )
        external
        view
        returns (uint256 cost)
    {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calCost(otSupply);
    }

    /// @inheritdoc IFTCurve
    function simMarginalPrice(uint256 otSupply) external view returns (uint256 price) {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calMarginalPrice(otSupply);
    }

    /// @inheritdoc IFTCurve
    function simMarginalPrice(
        address, /*market*/
        uint256, /*tokenId*/
        uint256 otSupply
    )
        external
        view
        returns (uint256 price)
    {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calMarginalPrice(otSupply);
    }

    /// @inheritdoc IFTCurve
    /// @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
    function extrapolateMintForOffchainOnly(address market, uint256 tokenId, uint256 otFrom, uint256 otDelta)
        external
        view
        returns (uint256 collateralFromUser, uint256 collateralToTreasury)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        (collateralFromUser, collateralToTreasury) = PowerMint.calSwap(curve, state.feeRate, otFrom, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
    function extrapolateRedeemForOffchainOnly(address market, uint256 tokenId, uint256 otFrom, uint256 otDelta)
        external
        view
        returns (uint256 collateralToUser, uint256 collateralToTreasury)
    {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        (collateralToUser, collateralToTreasury) =
            PowerRedeem.calSwap(curve, state.redeem, state.feeRate, otFrom, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralToUser = collateralToUser.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE); // effective sell price is lower
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    function simSeed(uint256[] calldata tokenIds, uint256[] calldata otDeltas, uint8 collateralDecimals, uint80 feeRate)
        external
        view
        returns (uint256 collateralFromUserTotal, uint256 collateralToTreasuryTotal)
    {
        if (tokenIds.length != otDeltas.length) revert Errors.MarketArrayLengthsMismatch();

        PowerMath.CurveParams memory curve = readCurve();
        uint256 len = tokenIds.length;
        uint256 collateralScale = 10 ** collateralDecimals;
        for (uint256 i = 0; i < len; ++i) {
            if (otDeltas[i] == 0) continue;

            // market is not created: ot supply starts at 0
            (uint256 collateralFromUser, uint256 collateralToTreasury) =
                PowerMint.calSwap(curve, feeRate, 0, otDeltas[i]);
            collateralFromUserTotal += collateralFromUser.fullMulDivUp(collateralScale, FTMath.FT_ONE); // effective buy price is higher
            collateralToTreasuryTotal += collateralToTreasury.fullMulDiv(collateralScale, FTMath.FT_ONE);
        }
    }
}
