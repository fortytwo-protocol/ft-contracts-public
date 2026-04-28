// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IRegistry} from "@ft/src/interfaces/IRegistry.sol";
import {PowerMath, PowerMint, PowerRedeem} from "@ft/src/curves/math/PowerMath.sol";
import {PowerLDAMint} from "@ft/src/curves/math/PowerLDAMath.sol";
import {LDAMath} from "@ft/src/curves/math/LDAMath.sol";
import {FTMath} from "@ft/lib/FTMath.sol";
import {RedeemMath} from "@ft/lib/RedeemMath.sol";
import {Errors} from "@ft/lib/Errors.sol";
import {Decoder} from "@ft/lib/Decoder.sol";
import {GuessParam} from "@ft/src/curves/CurveBase.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";

contract PowerLDACurve is IFTCurve {
    using PowerMath for PowerMath.CurveParams;
    using FixedPointMathLib for uint256;
    using FTMath for uint256;

    struct MarketState {
        RedeemMath.RedeemParams redeem;
        LDAMath.LDAPremiumParams premium;
        uint256 feeRate;
        uint256 otCurrent;
        uint256 tick;
    }

    // PowerCurve
    uint256 public immutable C1;
    uint256 public immutable C2;
    uint256 public immutable START;
    uint256 public immutable TIME_KINK;
    uint256 public immutable TIME_EXPONENT;
    uint256 public immutable GROWTH_C1;
    uint256 public immutable GROWTH_C2;
    uint256 public immutable TICK;

    // LDA
    uint256 public immutable PHI_DELTA_MAX;
    uint256 public immutable WINDOW_STATIC;

    constructor(
        uint256 _c1,
        uint256 _c2,
        uint256 _start,
        uint256 _timeKink,
        uint256 _timeExponent,
        uint256 _growthC1,
        uint256 _growthC2,
        uint256 _tick,
        uint256 _phiDeltaMax,
        uint256 _windowFixed
    ) {
        C1 = _c1;
        C2 = _c2;
        START = _start;
        // NOTE: "free" shares creates weird math problems especially when redeeming, so start from a non-free point
        PowerMath.CurveParams memory curve = readCurve();
        if (!curve.isValid()) revert Errors.CurveInvalidCost(START);

        TIME_KINK = _timeKink;
        TIME_EXPONENT = _timeExponent;
        GROWTH_C1 = _growthC1;
        GROWTH_C2 = _growthC2;

        TICK = _tick;

        PHI_DELTA_MAX = _phiDeltaMax;
        WINDOW_STATIC = _windowFixed;
    }

    /// @inheritdoc IFTCurve
    function calMarginalPrice(address market, uint256 tokenId) external view returns (uint256 price) {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);

        price = PowerLDAMint.calMarginalPrice(curve, state.premium, state.otCurrent);

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

        (collateralFromUser, collateralToTreasury) =
            PowerLDAMint.calSwap(curve, state.premium, state.feeRate, state.otCurrent, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE); // effective buy price is higher
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @dev same as PowerCurve.sol
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
    /// @notice seed does not pay LDA premiums
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

            // seed bypasses LDA premium
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

        (otDelta, collateralFromUser) = PowerLDAMint.guessOtDelta(
            curve, state.premium, state.feeRate, guess, collateralDeltaScaled, state.otCurrent, state.tick
        );
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @dev same as PowerCurve.sol
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

    /// @notice Read immutable curve params
    function readCurve() public view returns (PowerMath.CurveParams memory curve) {
        curve = PowerMath.CurveParams({c1: C1, c2: C2, start: START});
    }

    /// @notice Read state of market required for calculations, including LDA premium
    function readMarketState(address market, uint256 tokenId) public view returns (MarketState memory state) {
        address registry = IFTMarket(market).registry();
        (, uint256 feeRate,, uint128 timestampEnd,,) = IRegistry(registry).getConfig(market);

        uint256 otCurrent = IERC6909TokenSupply(market).totalSupply(tokenId);
        uint128 timestampStart = IFTMarket(market).timestampStart();

        RedeemMath.RedeemParams memory redeem = RedeemMath.newRedeemParams(
            timestampStart, timestampEnd, block.timestamp.toUint128(), TIME_KINK, TIME_EXPONENT, GROWTH_C1, GROWTH_C2
        );
        LDAMath.LDAPremiumParams memory premium =
            LDAMath.newPremiumParams(PHI_DELTA_MAX, WINDOW_STATIC, timestampStart, timestampEnd, block.timestamp);

        state = MarketState({redeem: redeem, premium: premium, feeRate: feeRate, otCurrent: otCurrent, tick: TICK});
    }

    /// @inheritdoc IFTCurve
    function simCost(uint256 otSupply) external view returns (uint256 cost) {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calCost(otSupply);
    }

    /// @inheritdoc IFTCurve
    /// @dev lda premium exists, thus do not rely on this as market cap is path-dependent
    function simCost(address market, uint256 tokenId, uint256 otSupply) external view returns (uint256 cost) {
        if (otSupply == 0) return 0;
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        (cost,) = PowerLDAMint.calSwap(curve, state.premium, 0, 0, otSupply);
    }

    /// @inheritdoc IFTCurve
    function simMarginalPrice(uint256 otSupply) external view returns (uint256 price) {
        PowerMath.CurveParams memory curve = readCurve();
        return curve.calMarginalPrice(otSupply);
    }

    /// @inheritdoc IFTCurve
    /// @dev lda premium exists, thus when market is still in lda window it returns a marginal price with lda
    function simMarginalPrice(address market, uint256 tokenId, uint256 otSupply) external view returns (uint256 price) {
        PowerMath.CurveParams memory curve = readCurve();
        MarketState memory state = readMarketState(market, tokenId);
        return PowerLDAMint.calMarginalPrice(curve, state.premium, otSupply);
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

        (collateralFromUser, collateralToTreasury) =
            PowerLDAMint.calSwap(curve, state.premium, state.feeRate, otFrom, otDelta);

        uint256 collateralDecimals = IFTMarket(market).collateralDecimals();
        collateralFromUser = collateralFromUser.fullMulDivUp(10 ** collateralDecimals, FTMath.FT_ONE);
        collateralToTreasury = collateralToTreasury.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    /// @inheritdoc IFTCurve
    /// @dev DO NOT RELY ON THIS FOR ONCHAIN LOGIC
    /// @dev same as PowerCurve.sol
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

            // market is not created: ot supply starts at 0 & no LDA premium
            (uint256 collateralFromUser, uint256 collateralToTreasury) =
                PowerMint.calSwap(curve, feeRate, 0, otDeltas[i]);
            collateralFromUserTotal += collateralFromUser.fullMulDivUp(collateralScale, FTMath.FT_ONE);
            collateralToTreasuryTotal += collateralToTreasury.fullMulDiv(collateralScale, FTMath.FT_ONE);
        }
    }
}
