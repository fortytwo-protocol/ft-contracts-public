// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {ClockMath, ClockMint} from "@ft/src/curves/math/ClockMath.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";
import {GuessParam} from "@ft/src/curves/CurveBase.sol";
import {Decoder} from "@ft/lib/Decoder.sol";

contract ClockCurve is IFTCurve {
    using ClockMath for ClockMath.CurveParams;
    using FixedPointMathLib for uint256;

    struct MarketState {
        uint256 feeRate;
        uint256 otCurrent;
        uint256 timePassed;
    }

    uint256 private immutable start;
    uint256 private immutable timePremiumMin;
    uint256 private immutable timePremiumMax;
    uint256 private immutable kink;

    constructor(uint256 _start, uint256 _timePremiumMax, uint256 _timePremiumMin, uint256 _kink) {
        start = _start;
        timePremiumMin = _timePremiumMin;
        timePremiumMax = _timePremiumMax;
        kink = _kink;

        ClockMath.CurveParams memory curve = readCurve();
        if (!curve.isValid()) revert Errors.CurveInvalidCost(start);
    }

    /// @inheritdoc IFTCurve
    function calMarginalPrice(address market, uint256 tokenId) external view returns (uint256 price) {
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        price = curve.calMarginalPrice(state.otCurrent, state.timePassed);

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
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        (collateralFromUser, collateralToTreasury) =
            ClockMint.calSwap(curve, state.feeRate, state.otCurrent, otDelta, state.timePassed);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @notice no redeems allowed, DO NOT redeem!
    function calRedeemValueByOtDelta(
        address, /*market*/
        uint256, /*tokenId*/
        uint256, /*otDelta*/
        bytes calldata /*data*/
    )
        external
        pure
        returns (uint256 collateralToUser, uint256 collateralToTreasury)
    {
        return (0, 0);
    }

    /// @inheritdoc IFTCurve
    function calSeedCostByOtDeltas(
        address market,
        uint256[] calldata tokenIds,
        uint256[] calldata otDeltas,
        bytes calldata /*dataSwap*/
    ) external view returns (uint256[] memory collateralsFromUser, uint256[] memory collateralsToTreasury) {
        if (tokenIds.length != otDeltas.length) revert Errors.MarketArrayLengthsMismatch();

        ClockMath.CurveParams memory curve = readCurve();

        uint256 len = tokenIds.length;
        collateralsFromUser = new uint256[](len);
        collateralsToTreasury = new uint256[](len);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        for (uint256 i = 0; i < len; ++i) {
            uint256 otDelta = otDeltas[i];
            if (otDelta == 0) continue;

            MarketState memory state = readMarketState(market, tokenIds[i]);

            // seed bypasses mint time premium
            (uint256 collateralFromUser, uint256 collateralToTreasury) =
                ClockMint.calSwap(curve, state.feeRate, state.otCurrent, otDelta, 0);
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
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        GuessParam memory guess = Decoder.decodeGuessParam(data);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        uint256 collateralDeltaScaled = collateralDelta.fullMulDiv(FTMath.FT_ONE, 10 ** collateralDecimals);

        (otDelta, collateralFromUser) = ClockMint.guessOtDelta(
            curve, state.feeRate, guess, collateralDeltaScaled, state.otCurrent, state.timePassed
        );
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @notice no redeems allowed, DO NOT redeem!
    function calOtDeltaByRedeemValue(
        address, /*market*/
        uint256, /*tokenId*/
        uint256, /*collateralDelta*/
        bytes calldata /*data*/
    )
        external
        pure
        returns (uint256 otDelta, uint256 collateralToUser)
    {
        return (type(uint256).max, 0);
    }

    /// @notice read immutable curve params
    function readCurve() public view returns (ClockMath.CurveParams memory curve) {
        curve = ClockMath.CurveParams({
            timePremiumMax: timePremiumMax, timePremiumMin: timePremiumMin, kink: kink, start: start
        });
    }

    ///@notice read state of market required for calculations
    function readMarketState(address market, uint256 tokenId) public view returns (MarketState memory state) {
        address registry = IFTMarket(market).registry();
        (, uint256 feeRate,, uint128 timestampEnd,,) = IRegistry(registry).getConfig(market);

        uint256 otCurrent = IERC6909TokenSupply(market).totalSupply(tokenId);

        uint128 timestampStart = IFTMarket(market).timestampStart();
        uint256 timePassed;
        if (timestampEnd <= timestampStart || block.timestamp >= timestampEnd) {
            timePassed = FTMath.FT_ONE;
        } else if (block.timestamp > timestampStart) {
            timePassed = (block.timestamp - timestampStart).fullMulDiv(FTMath.FT_ONE, timestampEnd - timestampStart);
        } else {
            timePassed = 0;
        }

        state = MarketState({feeRate: feeRate, otCurrent: otCurrent, timePassed: timePassed});
    }

    /// @inheritdoc IFTCurve
    /// @dev cost has 0 time premium here, also do not rely on this as market cap is path-dependent
    function simCost(uint256 otSupply) external view returns (uint256 cost) {
        ClockMath.CurveParams memory curve = readCurve();
        return curve.calCost(otSupply, 0);
    }

    /// @inheritdoc IFTCurve
    /// @dev time premium exists, thus do not rely on this as market cap is path-dependent
    function simCost(address market, uint256 tokenId, uint256 otSupply) external view returns (uint256 cost) {
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        return curve.calCost(otSupply, state.timePassed);
    }

    /// @inheritdoc IFTCurve
    /// @dev price has 0 time premium here, also do not rely on this as price is path-dependent
    function simMarginalPrice(uint256 otSupply) external view returns (uint256 price) {
        ClockMath.CurveParams memory curve = readCurve();
        return curve.calMarginalPrice(otSupply, 0);
    }

    /// @inheritdoc IFTCurve
    /// @dev time premium exists, thus do not rely on this as price is path-dependent
    function simMarginalPrice(address market, uint256 tokenId, uint256 otSupply) external view returns (uint256 price) {
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        return curve.calMarginalPrice(otSupply, state.timePassed);
    }

    /// @inheritdoc IFTCurve
    /// @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
    function extrapolateMintForOffchainOnly(address market, uint256 tokenId, uint256 otFrom, uint256 otDelta)
        external
        view
        returns (uint256 collateralFromUser, uint256 collateralToTreasury)
    {
        ClockMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        (collateralFromUser, collateralToTreasury) =
            ClockMint.calSwap(curve, state.feeRate, otFrom, otDelta, state.timePassed);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
    function extrapolateRedeemForOffchainOnly(
        address, /*market*/
        uint256, /*tokenId*/
        uint256, /*otFrom*/
        uint256 /*otDelta*/
    )
        external
        pure
        returns (uint256 collateralToUser, uint256 collateralToTreasury)
    {
        return (0, 0); // note: no redeems allowed!
    }

    /// @inheritdoc IFTCurve
    function simSeed(uint256[] calldata tokenIds, uint256[] calldata otDeltas, uint8 collateralDecimals, uint80 feeRate)
        external
        view
        returns (uint256 collateralFromUserTotal, uint256 collateralToTreasuryTotal)
    {
        if (tokenIds.length != otDeltas.length) revert Errors.MarketArrayLengthsMismatch();

        ClockMath.CurveParams memory curve = readCurve();
        uint256 len = tokenIds.length;
        uint256 collateralScale = 10 ** collateralDecimals;
        for (uint256 i = 0; i < len; ++i) {
            uint256 otDelta = otDeltas[i];
            if (otDelta == 0) continue;

            // market is not created: ot supply starts at 0 & timePassed is at 0
            (uint256 collateralFromUser, uint256 collateralToTreasury) =
                ClockMint.calSwap(curve, feeRate, 0, otDelta, 0);
            collateralFromUserTotal += collateralFromUser.fullMulDivUp(collateralScale, FTMath.FT_ONE); // effective buy price is higher
            collateralToTreasuryTotal += collateralToTreasury.fullMulDiv(collateralScale, FTMath.FT_ONE);
        }
    }
}
