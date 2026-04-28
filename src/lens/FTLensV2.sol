// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {IFTMarketV2} from "@ft/src/interfaces/IFTMarketV2.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {Market, MarketState, MarketDeployParams} from "@ft/lib/Market.sol";
import {Integrator} from "@ft/lib/Integrator.sol";
import {FTMath} from "@ft/lib/FTMath.sol";

struct MarketSnapshot {
    OtSnapshot[] ots;
    MarketDeployParams deploy;
    MarketState state;
}

struct OtSnapshot {
    uint256 tokenId;
    uint256 price;
    uint256 supply;
    uint256 totalMarketCap;
    uint256 payoutPerOt; /// @dev assuming this OT wins
}

struct UserOtSnapshot {
    uint256 tokenId;
    uint256 price;
    uint256 supply;
    uint256 totalMarketCap;
    uint256 otHolding;
    uint256 payoutUser; /// @dev accurate if finalised, else assuming this OT wins
    uint256 payoutPerOt; /// @dev accurate if finalised, else assuming this OT wins
}

struct MintQuote {
    uint256 collateralFromUser;
    uint256 collateralToTreasury;
    uint256 collateralToIntegrator;
    uint256 otToUser;
}

struct RedeemQuote {
    uint256 collateralToUser;
    uint256 collateralToTreasury;
    uint256 collateralToIntegrator;
    uint256 otFromUser;
    uint256 collateralMintValue;
}

struct TradeInput {
    uint256 tokenId;
    uint256 amount;
    bool isExactIn;
    bytes dataSwap;
    bytes dataGuess;
}

struct UserState {
    UserOtSnapshot[] ots;
    MarketDeployParams deploy;
    MarketState state;
    uint256 collateralClaimable;
}

/**
 * Used primarily for the frontend for simulating swaps or fetching swathes of onchain data.
 * As these are functions for the frontend, do not call them onchain. They are marked as non-view since simulating requires state changes.
 * For safety, do not approve anything tokens to this contract!
 *
 * Admittedly, the current code architecture was not built with simulations in mind.
 * It can only support ~90% of all requried simulations, notably being difficult to support sequence dependency.
 */
contract FTLensV2 {
    using FixedPointMathLib for uint256;

    bytes32 private constant _FT_V1_HASH = keccak256(bytes("FT_V1"));

    // used to hold everything required for mints. primarily to avoid stack too deep issues
    struct BatchStateMintPointer {
        IFTCurve curve;
        uint256 totalMarketCap;
        uint256[] supplies;
        bool[] seen;
        OtSnapshot[] pres;
        OtSnapshot[] posts;

        MintQuote[] quotes;
    }

    // used to hold everything required for mints. primarily to avoid stack too deep issues
    struct BatchStateMintUserPointer {
        IFTCurve curve;
        uint256 totalMarketCap;
        uint256[] supplies;
        bool[] seen;
        UserOtSnapshot[] pres;
        UserOtSnapshot[] posts;

        MintQuote[] quotes;

        uint256[] holdings;
    }

    // used to hold everything required for redeems. primarily to avoid stack too deep issues
    struct BatchStateRedeemPointer {
        IFTCurve curve;
        uint256 totalMarketCap;
        uint256[] supplies;
        bool[] seen;
        OtSnapshot[] pres;
        OtSnapshot[] posts;

        RedeemQuote[] quotes;
    }

    // used to hold everything required for redeems. primarily to avoid stack too deep issues
    struct BatchStateRedeemUserPointer {
        IFTCurve curve;
        uint256 totalMarketCap;
        uint256[] supplies;
        bool[] seen;
        UserOtSnapshot[] pres;
        UserOtSnapshot[] posts;

        RedeemQuote[] quotes;

        uint256[] holdings;
    }

    error LensDuplicateTokenIdInBatch(uint256 tradeIndex, uint256 tokenId);
    error LensInvalidTokenId(uint256 tokenId);

    function snapshotMarket(address market) public view returns (MarketSnapshot memory snapshot) {
        snapshot.state = IFTMarketV2(market).readState();
        snapshot.deploy = IFTMarketV2(market).readMarketDeployParams();

        snapshot.ots = new OtSnapshot[](snapshot.state.numOutcomes);
        for (uint256 i = 0; i < snapshot.state.numOutcomes; ++i) {
            snapshot.ots[i] = snapshotOt(market, Market.toTokenId(i));
        }
    }

    function snapshotOt(address market, uint256 tokenId) public view returns (OtSnapshot memory ot) {
        IFTCurve curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);

        uint8 otDecimals = IFTMarketV2(market).decimals(tokenId);

        ot.tokenId = tokenId;
        ot.supply = IFTMarketV2(market).totalSupply(tokenId);
        ot.price = curve.calMarginalPrice(market, tokenId);
        ot.payoutPerOt = IFTMarketV2(market).simPayout(tokenId, 1 * 10 ** otDecimals);
        ot.totalMarketCap = IFTMarketV2(market).totalMarketCap();
    }

    function snapshotUserOt(address market, uint256 tokenId, address user)
        public
        view
        returns (UserOtSnapshot memory snapshot)
    {
        MarketState memory state = IFTMarketV2(market).readState();

        snapshot = _snapshotUserOt(market, tokenId, user, state);
    }

    function getUserState(address market, address user) public view returns (UserState memory snap) {
        snap.state = IFTMarketV2(market).readState();
        snap.deploy = IFTMarketV2(market).readMarketDeployParams();

        uint256 numOutcomes = snap.state.numOutcomes;
        snap.ots = new UserOtSnapshot[](numOutcomes);

        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            snap.ots[i] = _snapshotUserOt(market, tokenId, user, snap.state);

            // note: checking resolution is important as adding up all ot where payout > 0 is misleading
            if (snap.state.isFinalised && Market.isWinner(snap.state.answer, tokenId)) {
                snap.collateralClaimable += snap.ots[i].payoutUser;
            }
        }
    }

    function simulateMint(
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps
    ) external returns (OtSnapshot memory pre, OtSnapshot memory post, MintQuote memory quote) {
        IFTCurve curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);

        pre = snapshotOt(market, tokenId);
        quote = _buildMintQuote(curve, market, tokenId, amount, isExactIn, dataSwap, dataGuess, integratorFeeBps);
        post = _composeOt(
            curve,
            market,
            tokenId,
            pre.supply + quote.otToUser,
            pre.totalMarketCap + quote.collateralFromUser - quote.collateralToIntegrator - quote.collateralToTreasury
        );
    }

    function simulateRedeem(
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps
    ) external returns (OtSnapshot memory pre, OtSnapshot memory post, RedeemQuote memory quote) {
        IFTCurve curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);

        pre = snapshotOt(market, tokenId);
        quote = _buildRedeemQuote(
            curve, market, tokenId, amount, isExactIn, dataSwap, dataGuess, integratorFeeBps, pre.supply
        );
        post = _composeOt(
            curve,
            market,
            tokenId,
            pre.supply - quote.otFromUser,
            pre.totalMarketCap - quote.collateralToUser - quote.collateralToIntegrator - quote.collateralToTreasury
        );
    }

    function simulateMintForUser(
        address market,
        uint256 tokenId,
        address user,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps
    ) external returns (UserOtSnapshot memory pre, UserOtSnapshot memory post, MintQuote memory quote) {
        IFTCurve curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);

        pre = snapshotUserOt(market, tokenId, user);
        quote = _buildMintQuote(curve, market, tokenId, amount, isExactIn, dataSwap, dataGuess, integratorFeeBps);
        post = _composeUserOt(
            curve,
            market,
            tokenId,
            pre.supply + quote.otToUser,
            pre.totalMarketCap + quote.collateralFromUser - quote.collateralToIntegrator - quote.collateralToTreasury,
            pre.otHolding + quote.otToUser
        );
    }

    function simulateRedeemForUser(
        address market,
        uint256 tokenId,
        address user,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps
    ) external returns (UserOtSnapshot memory pre, UserOtSnapshot memory post, RedeemQuote memory quote) {
        IFTCurve curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);

        pre = snapshotUserOt(market, tokenId, user);
        quote = _buildRedeemQuote(
            curve, market, tokenId, amount, isExactIn, dataSwap, dataGuess, integratorFeeBps, pre.supply
        );
        post = _composeUserOt(
            curve,
            market,
            tokenId,
            pre.supply - quote.otFromUser,
            pre.totalMarketCap - quote.collateralToUser - quote.collateralToIntegrator - quote.collateralToTreasury,
            pre.otHolding - quote.otFromUser
        );
    }

    function simulateMints(address market, TradeInput[] calldata trades, uint256 integratorFeeBps)
        external
        returns (OtSnapshot[] memory pres, OtSnapshot[] memory posts, MintQuote[] memory quotes)
    {
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);
        BatchStateMintPointer memory s = _initBatchStateMint(market, trades.length);

        for (uint256 i = 0; i < trades.length; ++i) {
            _stepMint(market, integratorFeeBps, s, trades, i);
        }

        return (s.pres, s.posts, s.quotes);
    }

    function simulateRedeems(address market, TradeInput[] calldata trades, uint256 integratorFeeBps)
        external
        returns (OtSnapshot[] memory pres, OtSnapshot[] memory posts, RedeemQuote[] memory quotes)
    {
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);
        BatchStateRedeemPointer memory s = _initBatchStateRedeem(market, trades.length);

        for (uint256 i = 0; i < trades.length; ++i) {
            _stepRedeem(market, integratorFeeBps, s, trades, i);
        }

        return (s.pres, s.posts, s.quotes);
    }

    function simulateMintsForUser(address market, address user, TradeInput[] calldata trades, uint256 integratorFeeBps)
        external
        returns (UserOtSnapshot[] memory pres, UserOtSnapshot[] memory posts, MintQuote[] memory quotes)
    {
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);
        BatchStateMintUserPointer memory s = _initBatchStateMintUser(market, user, trades.length);

        for (uint256 i = 0; i < trades.length; ++i) {
            _stepMintUser(market, integratorFeeBps, s, trades, i);
        }

        return (s.pres, s.posts, s.quotes);
    }

    function simulateRedeemsForUser(
        address market,
        address user,
        TradeInput[] calldata trades,
        uint256 integratorFeeBps
    ) external returns (UserOtSnapshot[] memory pres, UserOtSnapshot[] memory posts, RedeemQuote[] memory quotes) {
        integratorFeeBps = _resolveIntegratorFeeBps(market, integratorFeeBps);
        BatchStateRedeemUserPointer memory s = _initBatchStateRedeemUser(market, user, trades.length);

        for (uint256 i = 0; i < trades.length; ++i) {
            _stepRedeemUser(market, integratorFeeBps, s, trades, i);
        }

        return (s.pres, s.posts, s.quotes);
    }

    function _stepMint(
        address market,
        uint256 integratorFeeBps,
        BatchStateMintPointer memory s,
        TradeInput[] calldata trades,
        uint256 indexTrade
    ) internal {
        uint256 indexOutcome = _fromTokenIdToOutcomeIndex(trades[indexTrade].tokenId, s.supplies.length);
        if (s.seen[indexOutcome]) revert LensDuplicateTokenIdInBatch(indexTrade, trades[indexTrade].tokenId);
        s.seen[indexOutcome] = true;

        s.pres[indexTrade] =
            _composeOt(s.curve, market, trades[indexTrade].tokenId, s.supplies[indexOutcome], s.totalMarketCap);
        s.quotes[indexTrade] = _quoteMintForGroup(s.curve, market, integratorFeeBps, trades[indexTrade]);

        s.supplies[indexOutcome] += s.quotes[indexTrade].otToUser;
        s.totalMarketCap += s.quotes[indexTrade].collateralFromUser - s.quotes[indexTrade].collateralToIntegrator
        - s.quotes[indexTrade].collateralToTreasury;

        s.posts[indexTrade] =
            _composeOt(s.curve, market, trades[indexTrade].tokenId, s.supplies[indexOutcome], s.totalMarketCap);
    }

    function _stepRedeem(
        address market,
        uint256 integratorFeeBps,
        BatchStateRedeemPointer memory s,
        TradeInput[] calldata trades,
        uint256 indexTrade
    ) internal {
        uint256 indexOutcome = _fromTokenIdToOutcomeIndex(trades[indexTrade].tokenId, s.supplies.length);
        if (s.seen[indexOutcome]) revert LensDuplicateTokenIdInBatch(indexTrade, trades[indexTrade].tokenId);
        s.seen[indexOutcome] = true;

        s.pres[indexTrade] =
            _composeOt(s.curve, market, trades[indexTrade].tokenId, s.supplies[indexOutcome], s.totalMarketCap);
        s.quotes[indexTrade] =
            _quoteRedeemForGroup(s.curve, market, integratorFeeBps, trades[indexTrade], s.supplies[indexOutcome]);

        s.supplies[indexOutcome] -= s.quotes[indexTrade].otFromUser;
        s.totalMarketCap -= s.quotes[indexTrade].collateralToUser + s.quotes[indexTrade].collateralToIntegrator
        + s.quotes[indexTrade].collateralToTreasury;

        s.posts[indexTrade] =
            _composeOt(s.curve, market, trades[indexTrade].tokenId, s.supplies[indexOutcome], s.totalMarketCap);
    }

    function _stepMintUser(
        address market,
        uint256 integratorFeeBps,
        BatchStateMintUserPointer memory s,
        TradeInput[] calldata trades,
        uint256 indexTrade
    ) internal {
        uint256 indexOutcome = _fromTokenIdToOutcomeIndex(trades[indexTrade].tokenId, s.supplies.length);
        if (s.seen[indexOutcome]) revert LensDuplicateTokenIdInBatch(indexTrade, trades[indexTrade].tokenId);
        s.seen[indexOutcome] = true;

        s.pres[indexTrade] = _composeUserOt(
            s.curve,
            market,
            trades[indexTrade].tokenId,
            s.supplies[indexOutcome],
            s.totalMarketCap,
            s.holdings[indexOutcome]
        );
        s.quotes[indexTrade] = _quoteMintForGroup(s.curve, market, integratorFeeBps, trades[indexTrade]);

        s.supplies[indexOutcome] += s.quotes[indexTrade].otToUser;
        s.holdings[indexOutcome] += s.quotes[indexTrade].otToUser;
        s.totalMarketCap += s.quotes[indexTrade].collateralFromUser - s.quotes[indexTrade].collateralToIntegrator
        - s.quotes[indexTrade].collateralToTreasury;

        s.posts[indexTrade] = _composeUserOt(
            s.curve,
            market,
            trades[indexTrade].tokenId,
            s.supplies[indexOutcome],
            s.totalMarketCap,
            s.holdings[indexOutcome]
        );
    }

    function _stepRedeemUser(
        address market,
        uint256 integratorFeeBps,
        BatchStateRedeemUserPointer memory s,
        TradeInput[] calldata trades,
        uint256 indexTrade
    ) internal {
        uint256 indexOutcome = _fromTokenIdToOutcomeIndex(trades[indexTrade].tokenId, s.supplies.length);
        if (s.seen[indexOutcome]) revert LensDuplicateTokenIdInBatch(indexTrade, trades[indexTrade].tokenId);
        s.seen[indexOutcome] = true;

        s.pres[indexTrade] = _composeUserOt(
            s.curve,
            market,
            trades[indexTrade].tokenId,
            s.supplies[indexOutcome],
            s.totalMarketCap,
            s.holdings[indexOutcome]
        );
        s.quotes[indexTrade] =
            _quoteRedeemForGroup(s.curve, market, integratorFeeBps, trades[indexTrade], s.supplies[indexOutcome]);

        s.supplies[indexOutcome] -= s.quotes[indexTrade].otFromUser;
        s.holdings[indexOutcome] -= s.quotes[indexTrade].otFromUser;
        s.totalMarketCap -= s.quotes[indexTrade].collateralToUser + s.quotes[indexTrade].collateralToIntegrator
        + s.quotes[indexTrade].collateralToTreasury;

        s.posts[indexTrade] = _composeUserOt(
            s.curve,
            market,
            trades[indexTrade].tokenId,
            s.supplies[indexOutcome],
            s.totalMarketCap,
            s.holdings[indexOutcome]
        );
    }

    function _quoteMintForGroup(IFTCurve curve, address market, uint256 integratorFeeBps, TradeInput calldata trade)
        internal
        returns (MintQuote memory)
    {
        return _buildMintQuote(
            curve,
            market,
            trade.tokenId,
            trade.amount,
            trade.isExactIn,
            trade.dataSwap,
            trade.dataGuess,
            integratorFeeBps
        );
    }

    function _quoteRedeemForGroup(
        IFTCurve curve,
        address market,
        uint256 integratorFeeBps,
        TradeInput calldata trade,
        uint256 otSupplyPre
    ) internal returns (RedeemQuote memory) {
        return _buildRedeemQuote(
            curve,
            market,
            trade.tokenId,
            trade.amount,
            trade.isExactIn,
            trade.dataSwap,
            trade.dataGuess,
            integratorFeeBps,
            otSupplyPre
        );
    }

    function _buildMintQuote(
        IFTCurve curve,
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps
    ) internal returns (MintQuote memory quote) {
        uint256 otOut;
        if (isExactIn) {
            // note: must be same as router
            (otOut,) = curve.calOtDeltaByMintCost(
                market, tokenId, Integrator.subIntegratorFee(amount, integratorFeeBps), dataGuess
            );
        } else {
            otOut = amount;
        }

        (uint256 collateralIn, uint256 collateralToTreasury) =
            curve.calMintCostByOtDelta(market, tokenId, otOut, dataSwap);

        uint256 collateralToIntegrator = Integrator.calIntegratorFee(collateralIn, integratorFeeBps);
        quote = MintQuote({
            collateralFromUser: collateralIn + collateralToIntegrator,
            collateralToTreasury: collateralToTreasury,
            collateralToIntegrator: collateralToIntegrator,
            otToUser: otOut
        });
    }

    function _buildRedeemQuote(
        IFTCurve curve,
        address market,
        uint256 tokenId,
        uint256 amount,
        bool isExactIn,
        bytes calldata dataSwap,
        bytes calldata dataGuess,
        uint256 integratorFeeBps,
        uint256 otSupplyPre
    ) internal returns (RedeemQuote memory quote) {
        if (isExactIn) {
            quote.otFromUser = amount;
        } else {
            // note: must be same as router
            (quote.otFromUser,) = curve.calOtDeltaByRedeemValue(
                market, tokenId, Integrator.includeIntegratorFee(amount, integratorFeeBps), dataGuess
            );
        }

        uint256 collateralOut;
        (collateralOut, quote.collateralToTreasury) =
            curve.calRedeemValueByOtDelta(market, tokenId, quote.otFromUser, dataSwap);

        quote.collateralToIntegrator = Integrator.calIntegratorFee(collateralOut, integratorFeeBps);
        quote.collateralToUser = collateralOut - quote.collateralToIntegrator;

        (uint256 mintWithFee, uint256 mintFee) =
            curve.extrapolateMintForOffchainOnly(market, tokenId, otSupplyPre - quote.otFromUser, quote.otFromUser);
        quote.collateralMintValue = mintWithFee - mintFee;
    }

    function _composeOt(IFTCurve curve, address market, uint256 tokenId, uint256 supply, uint256 totalMarketCap)
        internal
        view
        returns (OtSnapshot memory snap)
    {
        snap.tokenId = tokenId;
        snap.supply = supply;
        snap.totalMarketCap = totalMarketCap;
        snap.price = _calMarginalPrice(curve, market, tokenId, supply);
        snap.payoutPerOt = _calPayoutPerOt(market, tokenId, totalMarketCap, supply);
    }

    function _composeUserOt(
        IFTCurve curve,
        address market,
        uint256 tokenId,
        uint256 supply,
        uint256 totalMarketCap,
        uint256 holding
    ) internal view returns (UserOtSnapshot memory snap) {
        snap.tokenId = tokenId;
        snap.supply = supply;
        snap.totalMarketCap = totalMarketCap;
        snap.price = _calMarginalPrice(curve, market, tokenId, supply);
        snap.payoutPerOt = _calPayoutPerOt(market, tokenId, totalMarketCap, supply);
        snap.otHolding = holding;
        snap.payoutUser = _calPayoutUser(totalMarketCap, holding, supply);
    }

    function _snapshotUserOt(address market, uint256 tokenId, address user, MarketState memory state)
        internal
        view
        returns (UserOtSnapshot memory snapshot)
    {
        OtSnapshot memory ot = snapshotOt(market, tokenId);
        snapshot.tokenId = tokenId;
        snapshot.price = ot.price;
        snapshot.supply = ot.supply;
        snapshot.totalMarketCap = ot.totalMarketCap;
        snapshot.payoutPerOt = ot.payoutPerOt;
        snapshot.otHolding = IFTMarketV2(market).balanceOf(user, tokenId);

        if (state.isFinalised) {
            if (Market.isWinner(state.answer, tokenId)) {
                uint8 decimals = IFTMarketV2(market).decimals(tokenId);
                snapshot.payoutPerOt = IFTMarketV2(market).simPayout(state.answer, 10 ** decimals);
                snapshot.payoutUser = IFTMarketV2(market).simPayout(state.answer, snapshot.otHolding);
            } else {
                snapshot.payoutPerOt = 0;
                snapshot.payoutUser = 0;
            }
        } else {
            snapshot.payoutUser = IFTMarketV2(market).simPayout(tokenId, snapshot.otHolding);
        }
    }

    function _initBatchStateMint(address market, uint256 numTrades)
        internal
        view
        returns (BatchStateMintPointer memory s)
    {
        uint256 numOutcomes = IFTMarketV2(market).readState().numOutcomes;
        s.curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        s.totalMarketCap = IFTMarketV2(market).totalMarketCap();
        s.supplies = new uint256[](numOutcomes);
        s.seen = new bool[](numOutcomes);
        s.pres = new OtSnapshot[](numTrades);
        s.posts = new OtSnapshot[](numTrades);
        s.quotes = new MintQuote[](numTrades);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            s.supplies[i] = IFTMarketV2(market).totalSupply(Market.toTokenId(i));
        }
    }

    function _initBatchStateRedeem(address market, uint256 numTrades)
        internal
        view
        returns (BatchStateRedeemPointer memory s)
    {
        uint256 numOutcomes = IFTMarketV2(market).readState().numOutcomes;
        s.curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        s.totalMarketCap = IFTMarketV2(market).totalMarketCap();
        s.supplies = new uint256[](numOutcomes);
        s.seen = new bool[](numOutcomes);
        s.pres = new OtSnapshot[](numTrades);
        s.posts = new OtSnapshot[](numTrades);
        s.quotes = new RedeemQuote[](numTrades);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            s.supplies[i] = IFTMarketV2(market).totalSupply(Market.toTokenId(i));
        }
    }

    function _initBatchStateMintUser(address market, address user, uint256 numTrades)
        internal
        view
        returns (BatchStateMintUserPointer memory s)
    {
        uint256 numOutcomes = IFTMarketV2(market).readState().numOutcomes;
        s.curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        s.totalMarketCap = IFTMarketV2(market).totalMarketCap();
        s.supplies = new uint256[](numOutcomes);
        s.holdings = new uint256[](numOutcomes);
        s.seen = new bool[](numOutcomes);
        s.pres = new UserOtSnapshot[](numTrades);
        s.posts = new UserOtSnapshot[](numTrades);
        s.quotes = new MintQuote[](numTrades);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            s.supplies[i] = IFTMarketV2(market).totalSupply(tokenId);
            s.holdings[i] = IFTMarketV2(market).balanceOf(user, tokenId);
        }
    }

    function _initBatchStateRedeemUser(address market, address user, uint256 numTrades)
        internal
        view
        returns (BatchStateRedeemUserPointer memory s)
    {
        uint256 numOutcomes = IFTMarketV2(market).readState().numOutcomes;
        s.curve = IFTCurve(IFTMarketV2(market).readMarketDeployParams().curve);
        s.totalMarketCap = IFTMarketV2(market).totalMarketCap();
        s.supplies = new uint256[](numOutcomes);
        s.holdings = new uint256[](numOutcomes);
        s.seen = new bool[](numOutcomes);
        s.pres = new UserOtSnapshot[](numTrades);
        s.posts = new UserOtSnapshot[](numTrades);
        s.quotes = new RedeemQuote[](numTrades);
        for (uint256 i = 0; i < numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            s.supplies[i] = IFTMarketV2(market).totalSupply(tokenId);
            s.holdings[i] = IFTMarketV2(market).balanceOf(user, tokenId);
        }
    }

    function _fromTokenIdToOutcomeIndex(uint256 tokenId, uint256 numOutcomes) internal pure returns (uint256 idx) {
        if (!Market.isValidTokenId(tokenId)) revert LensInvalidTokenId(tokenId);
        idx = Market.fromTokenId(tokenId);
        if (idx >= numOutcomes) revert LensInvalidTokenId(tokenId);
    }

    function _calMarginalPrice(IFTCurve curve, address market, uint256 tokenId, uint256 supply)
        internal
        view
        returns (uint256 priceScaled)
    {
        uint256 priceRaw;
        try curve.simMarginalPrice(market, tokenId, supply) returns (uint256 p) {
            priceRaw = p;
        } catch {
            priceRaw = curve.simMarginalPrice(supply); // note: need to be backward compatible with old curves
        }
        uint8 collateralDecimals = IFTMarketV2(market).collateralDecimals();
        priceScaled = priceRaw.fullMulDiv(10 ** collateralDecimals, FTMath.FT_ONE);
    }

    function _calPayoutPerOt(address market, uint256 tokenId, uint256 totalMarketCap, uint256 supply)
        internal
        view
        returns (uint256)
    {
        if (supply == 0) return 0;
        uint8 otDecimals = IFTMarketV2(market).decimals(tokenId);
        return totalMarketCap.fullMulDiv(10 ** otDecimals, supply);
    }

    function _calPayoutUser(uint256 totalMarketCap, uint256 otHolding, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) return 0;
        return totalMarketCap.fullMulDiv(otHolding, supply);
    }

    function _resolveIntegratorFeeBps(address market, uint256 integratorFeeBps) internal view returns (uint256) {
        if (_isV1Market(market)) return 0;
        return integratorFeeBps;
    }

    /**
     * There a few ways to do this:
     * 1. store the router on the lens but it is now tied to a set of contracts which can be inflexible
     * 2. query the market's controller and try to query a function that only exists on V2 controller
     * 3. query market's version (only V1 controller deploys V1 markets)
     */
    function _isV1Market(address market) internal view returns (bool) {
        try IFTMarketV2(market).marketType() returns (string memory mt) {
            return keccak256(bytes(mt)) == _FT_V1_HASH;
        } catch {
            return false;
        }
    }
}
