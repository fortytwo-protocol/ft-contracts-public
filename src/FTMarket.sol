// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFTCurve} from "@ft/src/interfaces/IFTCurve.sol";
import {IFTMintCallback} from "@ft/src/interfaces/IFTCallback.sol";
import {Errors} from "@ft/lib/Errors.sol";
import "@ft/lib/TokenHelper.sol";
import "@ft/src/FTERC6909.sol";
import "@ft/lib/FTMath.sol";
import "@ft/src/interfaces/IRegistry.sol";
import "@ft/src/interfaces/IFTMarket.sol";
import "@ft/lib/Event.sol";
import "@ft/lib/Market.sol";
import "@ft/lib/StringLib.sol";
import {FTMarketController} from "@ft/src/controller/FTMarketController.sol";

/**
 * - Contract holds 0 of its own OT, but holds pool of funds for payout (total market cap)
 * - totalMarketCap is accounted internally to avoid imbalances due to direct transfers
 * - Mint/redeem/claim to market as receiver is avoided (abnormal behaviour)
 */
contract FTMarket is FTERC6909, IFTMarket, TokenHelper, ReentrancyGuard, HasFTEvents {
    using FixedPointMathLib for uint256;
    using Market for MarketState;
    using StringLib for string;
    using StringLib for StringLib.slice;

    string private constant OT_PREFIX = "OT";
    bytes internal constant EMPTY_BYTES = "";

    struct MarketStorage {
        uint256 totalMarketCap;
    }

    MarketStorage public _storage;

    address public immutable registry;
    address public immutable factory;

    // MARKET DEPLOY PARAMS
    address public immutable collateral;
    uint256 public immutable parentTokenId;
    bytes32 public immutable questionId;
    address public immutable curve;
    uint128 public immutable timestampStart;

    constructor(
        address _registry,
        address _factory,
        address _collateral,
        uint256 _parentTokenId,
        bytes32 _questionId,
        address _curve,
        uint128 _timestampStart
    ) FTERC6909(FTMath.FT_DECIMALS) {
        if (_registry == address(0) || _factory == address(0) || _collateral == address(0) || _curve == address(0)) {
            revert Errors.MarketZeroAddress();
        }

        registry = _registry;
        factory = _factory;

        // MARKET DEPLOY PARAMS
        collateral = _collateral;
        parentTokenId = _parentTokenId;
        questionId = _questionId;
        curve = _curve;
        timestampStart = _timestampStart;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert Errors.MarketUnauthorizedAccess(msg.sender, factory);
        _;
    }

    modifier whenUnpaused() {
        // pausing is honestly very damaging. the goal of pause should be to eventually remove the pause.
        // pausing can ONLY stop trading - it's impossible to stop anything after finalization.
        if (IRegistry(registry).isPaused()) revert Errors.MarketPaused();
        _;
    }

    /**
     * @notice Markets have to be seeded by the market creator. Seed can be done before market starts.
     * Seed can only mint and all seeded OT goes to treasury.
     * @dev seed transactions do not trigger callbacks
     * @param dataSwap bytes data to be consumed by IFTCurve of the market
     */
    function seed(uint256 tokenId, uint256 otSeed, bytes calldata dataSwap) external nonReentrant onlyFactory {
        MarketState memory market = readState();
        if (market.timestampEnd <= block.timestamp) revert Errors.MarketEnded();
        if (market.answer != 0 || market.isFinalised) revert Errors.MarketResolved();

        _mintCollateralToOt(market, tokenId, otSeed, dataSwap, EMPTY_BYTES, market.treasury);
    }

    /**
     * @notice Markets allow swapping collateral -> OT (called mint). Markets support mint exact OT. Exact collateral is supported elsewhere.
     * @dev Steps:
     *      1. External input validation
     *      2. Calculate swap amount via IFTCurve
     *      3. Mint to receiver
     *      4. Callback msg.sender with dataCallback
     *      5. Transfer from receiver (get what is due) & transfer fee to treasury
     * @dev Revert if not started, has ended or resolved.
     * @dev Callbacks to re-mint the same market is not allowed (intra-market mint is path-independent in nature)
     * @param dataSwap bytes data to be consumed by IFTCurve of the market
     * @param dataCallback arbitrary bytes data to be passed back to msg.sender via `onMint`. Empty bytes means no callback required.
     * @return collateralIn amount of collateral required from msg.sender
     */
    function mintCollateralToExactOt(
        address receiver,
        uint256 tokenId,
        uint256 otDeltaOut,
        bytes calldata dataSwap,
        bytes calldata dataCallback
    ) external nonReentrant whenUnpaused returns (uint256 collateralIn) {
        MarketState memory market = readState();
        FTMarketController controller = FTMarketController(factory);
        if (block.timestamp < market.timestampStart) revert Errors.MarketNotStarted();
        if (market.timestampEnd <= block.timestamp) revert Errors.MarketEnded();
        if (market.answer != 0 || market.isFinalised) revert Errors.MarketResolved();
        if (controller.isMarket(receiver)) revert Errors.MarketReceiverIsMarket();

        collateralIn = _mintCollateralToOt(market, tokenId, otDeltaOut, dataSwap, dataCallback, receiver);
    }

    /**
     * @notice Markets allow swapping OT -> collateral (called redeem). Markets support redeem exact OT. Exact collateral is supported elsewhere.
     * @dev Steps:
     *      1. External input validation
     *      2. Calculate swap amount via IFTCurve
     *      3. Burn from receiver (get what is due)
     *      4. Transfer to receiver & fee to treasury
     * @dev Revert if not started, has ended or resolved.
     * @param dataSwap bytes data to be consumed by IFTCurve of the market
     * @return collateralOut amount of collateral given to receiver
     */
    function redeemExactOtToCollateral(address receiver, uint256 tokenId, uint256 otDeltaIn, bytes calldata dataSwap)
        external
        nonReentrant
        whenUnpaused
        returns (uint256 collateralOut)
    {
        MarketState memory market = readState();
        FTMarketController controller = FTMarketController(factory);
        if (block.timestamp < market.timestampStart) revert Errors.MarketNotStarted();
        if (market.timestampEnd <= block.timestamp) revert Errors.MarketEnded();
        if (market.answer != 0 || market.isFinalised) revert Errors.MarketResolved();
        if (controller.isMarket(receiver)) revert Errors.MarketReceiverIsMarket();

        collateralOut = _redeemOtToCollateral(market, tokenId, otDeltaIn, dataSwap, receiver);
    }

    /**
     * @notice After the market's question is finalised, all holders can claim their payout by burning their OTs.
     * Only the OT of the winning outcome has a non-zero payout.
     * @notice In the event no one holds the winning OT (winners exist yet no one is a winner), payout goes to treasury to redistribute. THIS IS NOT A FEE.
     * @dev payout per OT = total market cap (at finalisation) / winning OTs (at finalisation)
     * @dev Revert if not finalised
     * @return payout amount of payout for claiming OTs specified
     */
    function claim(address receiver, uint256[] memory tokenIds, uint256[] memory otToBurn)
        external
        nonReentrant
        returns (uint256)
    {
        MarketState memory market = readState();
        FTMarketController controller = FTMarketController(factory);
        if (!market.isFinalised) revert Errors.MarketNotFinalised();
        if (market.answer == 0) revert Errors.MarketNotResolved(); // NOTE: should be an assert, but the devs who created solidity do not understand assertion programming
        if (market.answer >= (1 << market.numOutcomes)) revert Errors.MarketTooManyOutcomes();
        if (controller.isMarket(receiver)) revert Errors.MarketReceiverIsMarket();

        uint256 otSupplyWinning = _calWinningOtSupply(market);
        // NOTE: excess is NOT A FEE. It is used to handle the edge case of no winning total supply (divide by 0), excess should be transferred to treasury for redistribution
        (uint256 payout, uint256 excess) = _claim(market, otSupplyWinning, tokenIds, otToBurn, receiver);

        _writeState(market);

        // NOTE: excess is NOT A FEE. It is used to handle the edge case of no winning total supply (divide by 0), excess should be transferred to treasury for redistribution
        _transferOut(collateral, parentTokenId, market.treasury, excess);
        _transferOut(collateral, parentTokenId, receiver, payout);

        return payout;
    }

    /**
     * @notice Removes excess collateral to match internally accounted totalMarketCap
     * @dev Only support market's collateral token, skim any token has too many edge cases.
     * @dev Does not interfere with other functions, note the `external` modifier
     */
    function skim() external nonReentrant {
        MarketState memory market = readState();
        uint256 excess = _selfBalance(collateral, parentTokenId) - market.totalMarketCap;
        _transferOut(collateral, parentTokenId, market.treasury, excess);
    }

    /**
     * @dev caller is always the msg.sender
     */
    function _mintCollateralToOt(
        MarketState memory market,
        uint256 tokenId,
        uint256 otDeltaOut,
        bytes memory dataSwap,
        bytes memory dataCallback,
        address receiver
    ) internal returns (uint256) {
        (uint256 collateralDeltaIn, uint256 collateralToTreasury) =
            market.mintCollateralToOt(tokenId, otDeltaOut, dataSwap);

        _writeState(market);

        _mint(receiver, tokenId, otDeltaOut);

        emit MintSwap(msg.sender, receiver, tokenId, collateralDeltaIn, otDeltaOut, collateralToTreasury);

        if (dataCallback.length > 0) {
            IFTMintCallback(msg.sender).onMint(collateralDeltaIn, otDeltaOut, dataCallback);
        }
        _transferIn(collateral, parentTokenId, msg.sender, collateralDeltaIn);
        _transferOut(collateral, parentTokenId, market.treasury, collateralToTreasury);

        // final check: mint cost >= redeem value
        (uint256 collateralRedeemUserValue, uint256 collateralRedeemFee) =
            market.curve.calRedeemValueByOtDelta(market.market, tokenId, otDeltaOut, dataSwap);
        if ((collateralRedeemUserValue + collateralRedeemFee) > (collateralDeltaIn - collateralToTreasury)) {
            revert Errors.MarketSwapPriceInvalidated(collateralDeltaIn, otDeltaOut);
        }

        return collateralDeltaIn;
    }

    /**
     * @dev caller is always the msg.sender
     */
    function _redeemOtToCollateral(
        MarketState memory market,
        uint256 tokenId,
        uint256 otDeltaIn,
        bytes memory dataSwap,
        address receiver
    ) internal returns (uint256) {
        (uint256 collateralToUser, uint256 collateralToTreasury) =
            market.redeemOtToCollateral(tokenId, otDeltaIn, dataSwap);

        _writeState(market);

        emit RedeemSwap(msg.sender, receiver, tokenId, collateralToUser, otDeltaIn, collateralToTreasury);

        _burn(msg.sender, tokenId, otDeltaIn);
        _transferOut(collateral, parentTokenId, receiver, collateralToUser);
        _transferOut(collateral, parentTokenId, market.treasury, collateralToTreasury);

        // final check: mint cost >= redeem value
        (uint256 collateralMintCost, uint256 collateralMintFee) =
            market.curve.calMintCostByOtDelta(market.market, tokenId, otDeltaIn, dataSwap);
        if ((collateralMintCost - collateralMintFee) < (collateralToUser + collateralToTreasury)) {
            revert Errors.MarketSwapPriceInvalidated((collateralToUser + collateralToTreasury), otDeltaIn);
        }

        return collateralToUser;
    }

    function _calWinningOtSupply(MarketState memory market) internal view returns (uint256 otSupplyWinning) {
        for (uint256 i = 0; i < market.numOutcomes; ++i) {
            uint256 tokenId = Market.toTokenId(i);
            if (Market.isWinner(market.answer, tokenId)) {
                otSupplyWinning += totalSupply(tokenId);
            }
        }
    }

    /**
     * @dev There's ~2 ways to calculate claims:
     * 1. On first claim, calculate the payoutPerOt once based on initial state and cache it. Then use it for every claim. This creates DUST and is stateful.
     * 2. On every claim, calculate the payoutPerOt based on total market cap and remaining winning OT. Then use it for that claim. This create NO DUST and is stateless
     * 3. You can try a hybrid of 1 & 2 (e.g caching the winning OTs and dynamically computing payoutPerOt). This adds more lines of code (liability).
     *
     * Option 1 vs 2 is primarily a matter of dust & statefulness. Option 2 is chosen to avoid accumulated dust (e.g 1million of 1 wei OT claims is not dust anymore)
     * I am aware that in the extreme worst case scenario we can have up to 255 different outcomes, and all of them can be winners, making the gas cost very expensive to recompute for every claim due to the number of SLOADs.
     * Outside of the code, it is however, indeed weird to create a prediction event where every outcome is correct.
     *
     * @dev event emission here is finicky at best, primarily as the backend stops working if the events are not a per-token-ledger-based whilst being 100% precise (hahaha)
     * However, claiming onchain uses a batch claim to reduce the number of round downs for the user.
     * To solve this, events for each winning claimed OT has a proportional payout except the last winning claimed OT which has the remainder of payout.
     *
     * @dev caller is always the msg.sender
     *
     */
    function _claim(
        MarketState memory market,
        uint256 otSupplyWinning,
        uint256[] memory tokenIds,
        uint256[] memory otToBurn,
        address receiver
    ) internal returns (uint256 payout, uint256 excess) {
        // 1. calculate claim
        uint256 otUserWinning;
        (payout, excess, otUserWinning) = market.claim(tokenIds, otToBurn, otSupplyWinning);

        // 2a. find last winning OT index -> last winning claim has payout of remainder
        uint256 len = tokenIds.length;
        uint256 idxLastWinningOt = type(uint256).max;
        for (uint256 i = len; i > 0; --i) {
            uint256 idx = i - 1;
            uint256 tokenId = tokenIds[idx];
            uint256 otBurned = otToBurn[idx];
            if (otBurned != 0 && Market.isWinner(market.answer, tokenId)) {
                idxLastWinningOt = idx;
                break;
            }
        }

        // 2b. emit event for each OT claimed
        // 3. burn all non-zero claims
        uint256 payoutRemaining = payout;
        for (uint256 i = 0; i < len; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 otBurned = otToBurn[i];
            if (otBurned == 0) {
                continue; // user is not claiming => don't create a false positive event
            }

            _burn(msg.sender, tokenId, otBurned);
            if (Market.isWinner(market.answer, tokenId)) {
                uint256 payoutProportional;
                if (i != idxLastWinningOt) {
                    payoutProportional = payout.fullMulDiv(otBurned, otUserWinning);
                    payoutRemaining -= payoutProportional;
                } else {
                    payoutProportional = payoutRemaining;
                }
                emit ClaimPayout(msg.sender, receiver, tokenId, otBurned, payoutProportional);
            } else {
                // losers don't receive anything
                emit ClaimPayout(msg.sender, receiver, tokenId, otBurned, 0);
            }
        }
    }

    /**
     * @notice Read function to simulate the payout given an answer. Especially useful before market end
     * @param answerSim answer to be simulated
     * @param otUserWinning amount of winning OT to claim for payout calculation
     */
    function simPayout(uint256 answerSim, uint256 otUserWinning) external view returns (uint256 payout) {
        MarketState memory market = readState();
        market.answer = answerSim;

        uint256 otSupplyWinning = _calWinningOtSupply(market);
        if (otSupplyWinning > 0) {
            return market.totalMarketCap.fullMulDiv(otUserWinning, otSupplyWinning);
        } else {
            return 0;
        }
    }

    /**
     * @notice Read total pool of funds in the market (aka totalMarketCap)
     */
    function totalMarketCap() external view returns (uint256) {
        return _storage.totalMarketCap;
    }

    /**
     * @notice Read total supplies of all OTs in the market
     */
    function totalSupplies() external view returns (uint256[] memory supplies) {
        uint256 numOutcomes = IRegistry(registry).getNumOutcomes(questionId);
        supplies = new uint256[](numOutcomes);
        for (uint256 i = 0; i < numOutcomes; i++) {
            uint256 tokenId = Market.toTokenId(i);
            supplies[i] = totalSupply(tokenId);
        }
    }

    /**
     * @notice used for market versioning or market logic differentiation
     */
    function marketType() external pure returns (string memory) {
        return "FT_V1";
    }

    /**
     * @notice helper function to get decimals of collateral
     */
    function collateralDecimals() external view returns (uint8 decimals) {
        return _collateralDecimals(collateral, parentTokenId);
    }

    /**
     * @notice read all storage values (externally & internally) into memory for gas-efficiency & data encapsulation
     */
    function readState() public view returns (MarketState memory market) {
        // immutable
        market.market = address(this);
        market.curve = IFTCurve(curve);
        market.timestampStart = timestampStart;

        // mutable, market related
        market.totalMarketCap = _storage.totalMarketCap;

        // mutable, question related
        (address treasury,/*feeRate*/, uint256 numOutcomes, uint128 timestampEnd, uint256 answer, bool isFinalised) =
            IRegistry(registry).getConfig(address(this));
        market.treasury = treasury;
        market.numOutcomes = numOutcomes;
        market.timestampEnd = timestampEnd;
        market.answer = answer;
        market.isFinalised = isFinalised;
    }

    /**
     * @notice write memory into internal storage (external must be an explicit external call)
     */
    function _writeState(MarketState memory market) internal {
        _storage.totalMarketCap = market.totalMarketCap;
    }

    /**
     * @notice read immutable deploy parameters used to create market
     */
    function readMarketDeployParams() external view returns (MarketDeployParams memory) {
        return MarketDeployParams({
            collateral: collateral,
            parentTokenId: parentTokenId,
            questionId: questionId,
            curve: address(curve),
            timestampStart: timestampStart
        });
    }

    /**
     * @notice naming convention: OT <NAME> <COLLATERAL>. Nested collaterals will have OT prefix stripped for better readability
     * @dev naming does not change, feel free to cache it offchain
     * @inheritdoc IERC6909Metadata
     */
    function name(uint256 tokenId) external view override(FTERC6909, IERC6909Metadata) returns (string memory) {
        string[] memory names = IRegistry(registry).getOutcomeNames(questionId);
        if (!Market.isValidTokenId(tokenId) || tokenId > Market.toTokenId(names.length - 1)) {
            revert Errors.MarketInvalidTokenId(tokenId);
        }

        string memory nameOutcome = names[Market.fromTokenId(tokenId)];
        string memory nameCollateral = _stripOTPrefix(_collateralName(collateral, parentTokenId));
        return _concat(OT_PREFIX, nameOutcome, nameCollateral, " ");
    }

    /**
     * @notice naming convention: OT-<NAME>-<COLLATERAL>. Nested collaterals will have OT prefix stripped for better readability
     * @dev naming does not change, feel free to cache it offchain
     * @inheritdoc IERC6909Metadata
     */
    function symbol(uint256 tokenId) external view override(FTERC6909, IERC6909Metadata) returns (string memory) {
        string[] memory names = IRegistry(registry).getOutcomeNames(questionId);
        if (!Market.isValidTokenId(tokenId) || tokenId > Market.toTokenId(names.length - 1)) {
            revert Errors.MarketInvalidTokenId(tokenId);
        }

        string memory nameOutcome = names[Market.fromTokenId(tokenId)];
        string memory nameCollateral = _stripOTPrefix(_collateralSymbol(collateral, parentTokenId));
        return _concat(OT_PREFIX, nameOutcome, nameCollateral, "-");
    }

    function _concat(
        string memory namePrefix,
        string memory nameOutcome,
        string memory nameCollateral,
        string memory delimiter
    ) private pure returns (string memory) {
        return string(abi.encodePacked(namePrefix, delimiter, nameOutcome, delimiter, nameCollateral));
    }

    function _stripOTPrefix(string memory _str) private pure returns (string memory) {
        StringLib.slice memory str = _str.toSlice();
        StringLib.slice memory otWithSpace = string.concat(OT_PREFIX, " ").toSlice();
        StringLib.slice memory otWithDash = string.concat(OT_PREFIX, "-").toSlice();
        return str.beyond(otWithSpace).beyond(otWithDash).toString();
    }

    function _transfer(address from, address to, uint256 id, uint256 amount) internal override {
        FTMarketController controller = FTMarketController(factory);
        if (controller.isMarket(to) && !controller.isMarket(msg.sender)) {
            revert Errors.MarketReceiverIsMarket();
        }
        super._transfer(from, to, id, amount);
    }
}
