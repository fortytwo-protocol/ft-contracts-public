// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFTMarket} from "@ft/src/interfaces/IFTMarket.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {Market, MarketState, MarketDeployParams} from "@ft/lib/Market.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

struct MarketSnapshot {
    OtSnapshot[] ots;
    MarketDeployParams deploy;
    MarketState state;
}

struct OtSnapshot {
    uint256 price;
    uint256 supply;
    uint256 totalMarketCap;
    uint256 payoutPerOt; /// @dev assuming this OT wins
}

struct SimulatedUserOtState {
    uint256 price;
    uint256 supply;
    uint256 totalMarketCap;
    uint256 otHolding;
    uint256 payoutUser; /// @dev assuming this OT wins
    uint256 payoutPerOt; /// @dev assuming this OT wins
}

struct SimulatedMintQuote {
    uint256 collateralFromUser;
    uint256 collateralToTreasury;
    uint256 otToUser;
}

struct SimulatedRedeemQuote {
    uint256 collateralToUser;
    uint256 collateralToTreasury;
    uint256 otFromUser;
    uint256 collateralMintValue;
}

/**
 * Used primarily for the frontend for simulating swaps or fetching swathes of onchain data.
 * As these are functions for the frontend, do not call them onchain. They are marked as non-view since simulating requires state changes.
 * For safety, do not approve anything tokens to this contract!
 *
 * Admittedly, the current code architecture was not built with simulations in mind.
 * It can only support ~90% of all requried simulations, notably being difficult to support sequence dependency.
 */
contract FTLensBV1 {
    using FixedPointMathLib for uint256;

    function snapshotMarket(address market) public view returns (MarketSnapshot memory snapshot) {
        snapshot.state = IFTMarket(market).readState();
        snapshot.deploy = IFTMarket(market).readMarketDeployParams();

        snapshot.ots = new OtSnapshot[](snapshot.state.numOutcomes);
        for (uint256 i = 0; i < snapshot.state.numOutcomes; ++i) {
            snapshot.ots[i] = snapshotOt(market, Market.toTokenId(i));
        }
    }

    function snapshotOt(address market, uint256 tokenId) public view returns (OtSnapshot memory ot) {
        MarketDeployParams memory deploy = IFTMarket(market).readMarketDeployParams();
        IFTCurve curve = IFTCurve(deploy.curve);

        uint8 decimals = IFTMarket(market).decimals(tokenId);

        ot.supply = IFTMarket(market).totalSupply(tokenId);
        ot.price = curve.calMarginalPrice(market, tokenId);
        ot.payoutPerOt = IFTMarket(market).simPayout(tokenId, 1 * 10 ** decimals);
        ot.totalMarketCap = IFTMarket(market).totalMarketCap();
    }

    function snapshotUserOtState(address market, uint256 tokenId, address user)
        public
        view
        returns (SimulatedUserOtState memory state)
    {
        MarketDeployParams memory deploy = IFTMarket(market).readMarketDeployParams();
        IFTCurve curve = IFTCurve(deploy.curve);

        uint8 decimals = IFTMarket(market).decimals(tokenId);

        state.supply = IFTMarket(market).totalSupply(tokenId);
        state.price = curve.calMarginalPrice(market, tokenId);
        state.totalMarketCap = IFTMarket(market).totalMarketCap();
        state.payoutPerOt = IFTMarket(market).simPayout(tokenId, 1 * 10 ** decimals);
        state.otHolding = IFTMarket(market).balanceOf(user, tokenId);
        state.payoutUser = IFTMarket(market).simPayout(tokenId, state.otHolding);
    }

    function simulateMintNoUser(
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) external returns (OtSnapshot memory pre, OtSnapshot memory post, SimulatedMintQuote memory quote) {
        pre = snapshotOt(market, tokenId);

        IFTCurve curve = IFTCurve(IFTMarket(market).readMarketDeployParams().curve);
        uint256 otOut;
        if (isExactIn) {
            (otOut,) = curve.calOtDeltaByMintCost(market, tokenId, amount, dataGuess);
        } else {
            otOut = amount;
        }

        quote = _buildMintQuote(curve, market, tokenId, otOut, dataSwap);

        uint8 decimals = IFTMarket(market).decimals(tokenId);
        post.supply = pre.supply + quote.otToUser;
        post.price = curve.simMarginalPrice(post.supply);
        post.totalMarketCap = pre.totalMarketCap + quote.collateralFromUser - quote.collateralToTreasury;
        post.payoutPerOt = post.totalMarketCap.fullMulDiv(10 ** decimals, post.supply);
    }

    function simulateMint(
        address market,
        uint256 tokenId,
        address user,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    )
        external
        returns (SimulatedUserOtState memory pre, SimulatedUserOtState memory post, SimulatedMintQuote memory quote)
    {
        pre = snapshotUserOtState(market, tokenId, user);

        uint256 otOut;
        IFTCurve curve = IFTCurve(IFTMarket(market).readMarketDeployParams().curve);
        if (isExactIn) {
            (otOut,) = curve.calOtDeltaByMintCost(market, tokenId, amount, dataGuess);
        } else {
            otOut = amount;
        }

        quote = _buildMintQuote(curve, market, tokenId, otOut, dataSwap);

        uint8 decimals = IFTMarket(market).decimals(tokenId);
        post.supply = pre.supply + quote.otToUser;
        post.price = curve.simMarginalPrice(post.supply);
        post.totalMarketCap = pre.totalMarketCap + quote.collateralFromUser - quote.collateralToTreasury;
        post.payoutPerOt = post.totalMarketCap.fullMulDiv(10 ** decimals, post.supply);

        post.otHolding = pre.otHolding + quote.otToUser;
        post.payoutUser = post.totalMarketCap.fullMulDiv(post.otHolding, post.supply);
    }

    function simulateRedeemNoUser(
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    ) external returns (OtSnapshot memory pre, OtSnapshot memory post, SimulatedRedeemQuote memory quote) {
        pre = snapshotOt(market, tokenId);

        IFTCurve curve = IFTCurve(IFTMarket(market).readMarketDeployParams().curve);
        uint256 otIn;
        if (isExactIn) {
            otIn = amount;
        } else {
            (otIn,) = curve.calOtDeltaByRedeemValue(market, tokenId, amount, dataGuess);
        }

        quote = _buildRedeemQuote(curve, market, tokenId, otIn, dataSwap, pre.supply);

        uint8 decimals = IFTMarket(market).decimals(tokenId);
        post.supply = pre.supply - quote.otFromUser; // build ensures won't fail
        post.price = curve.simMarginalPrice(post.supply);
        post.totalMarketCap = pre.totalMarketCap - quote.collateralToUser - quote.collateralToTreasury;
        post.payoutPerOt = post.totalMarketCap.fullMulDiv(10 ** decimals, post.supply);
    }

    function simulateRedeem(
        address market,
        uint256 tokenId,
        address user,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess
    )
        external
        returns (SimulatedUserOtState memory pre, SimulatedUserOtState memory post, SimulatedRedeemQuote memory quote)
    {
        pre = snapshotUserOtState(market, tokenId, user);

        IFTCurve curve = IFTCurve(IFTMarket(market).readMarketDeployParams().curve);
        uint256 otIn;
        if (isExactIn) {
            otIn = amount;
        } else {
            (otIn,) = curve.calOtDeltaByRedeemValue(market, tokenId, amount, dataGuess);
        }

        quote = _buildRedeemQuote(curve, market, tokenId, otIn, dataSwap, pre.supply);

        uint8 decimals = IFTMarket(market).decimals(tokenId);
        post.supply = pre.supply - quote.otFromUser; // build ensures won't fail
        post.price = curve.simMarginalPrice(post.supply);
        post.totalMarketCap = pre.totalMarketCap - quote.collateralToTreasury - quote.collateralToUser;
        post.payoutPerOt = post.totalMarketCap.fullMulDiv(10 ** decimals, post.supply);

        post.otHolding = pre.otHolding - quote.otFromUser;
        post.payoutUser = post.totalMarketCap.fullMulDiv(post.otHolding, post.supply);
    }

    function _buildMintQuote(IFTCurve curve, address market, uint256 tokenId, uint256 otOut, bytes calldata dataSwap)
        internal
        returns (SimulatedMintQuote memory quote)
    {
        (uint256 collateralFromUser, uint256 collateralToTreasury) =
            curve.calMintCostByOtDelta(market, tokenId, otOut, dataSwap);
        quote = SimulatedMintQuote({
            collateralFromUser: collateralFromUser, collateralToTreasury: collateralToTreasury, otToUser: otOut
        });
    }

    function _buildRedeemQuote(
        IFTCurve curve,
        address market,
        uint256 tokenId,
        uint256 otIn,
        bytes calldata dataSwap,
        uint256 otSupplyPre
    ) internal returns (SimulatedRedeemQuote memory quote) {
        (uint256 collateralToUser, uint256 collateralToTreasury) =
            curve.calRedeemValueByOtDelta(market, tokenId, otIn, dataSwap);
        (uint256 collateralMintWithFees, uint256 collateralMintFee) =
            curve.extrapolateMintForOffchainOnly(market, tokenId, otSupplyPre - otIn, otIn);

        quote = SimulatedRedeemQuote({
            collateralToUser: collateralToUser,
            collateralToTreasury: collateralToTreasury,
            otFromUser: otIn,
            collateralMintValue: collateralMintWithFees - collateralMintFee
        });
    }
}
