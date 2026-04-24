// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @dev NOTE: a lot of learnings are inspired from mangrove
 * All FortyTwo related events are listed here
 */
interface HasFTEvents {
    /**
     * Events in solidity are a lose-only feature.
     * If you look at it in the perspective of a gas efficiency purist, every event and additional field in the event adds gas.
     * Spamming events is also bizzare since many events become additional lines of liability(code) whilst providing zero benefits.
     * However, trying to emit as few events as possible and with as few fields as possible misses the original intent of events as offchain consumers cannot effectively consume these events.
     * In order words - with events, everyone loses.
     *
     * We can try to minimise our Ls via these main considerations:
     * - Minimise gas usage (don't spam events)
     * - An indexer must be able to monitor or create the state of FortyTwo
     * - It should be possible to query historical information such as marginal prices, total cost, total supply via RPC calls & block tags. This is especially important in reconciling indexed events with onchain state.
     * - Any hot data requirements should and must be accessed via RPC calls instead of events.
     *
     * It is nontrivial to find the "best" solution, especially since they are in conflict and continual development exists.
     */
    /* FortyTwo Creation & Configuration */

    /**
     * Emitted when creating new market
     */
    event CreateNewMarket(
        address indexed market,
        address collateral,
        uint256 parentTokenId,
        bytes32 questionId,
        address curve,
        uint256 timestampStart
    );

    /**
     * Emitted when creating new question
     *
     * NOTE: yes, you can get the title from calling the ptr...
     *
     * @dev this event is a legacy event and is only emitted by `FTMarketController.sol`. Please see the version CreateNewQuestionV<latest>
     */
    event CreateNewQuestion(bytes32 indexed questionId, string title, address ptr);

    /**
     * Emitted when adding an outcome to a question
     */
    event AddOutcome(bytes32 indexed questionId, uint256 indexOutcomeFromZero, string name);

    /**
     * Emitted when creating a new question (timestampPrev is 0) or extending the end timestamp of an existing market
     *
     * Please use this as a single source of truth/a ledger of amendments to the end timestamp, instead of attempting to track end timestamp via multiple possible event sources.
     * Please reconcile by identifying missing timestamps between timestampPrev & timestampNext. All questions must have exactly one event where timestampPrev is 0.
     *
     * @dev this event is a legacy event and is only emitted by `FTMarketController.sol`. Please see ModifyEnd which has the same data but different naming for better clarity.
     * In this version, end timestamp can only be extended to ensure that only the earliest timestamp is used for all questions
     */
    event ExtendEnd(bytes32 indexed questionId, uint128 timestampPrev, uint128 timestampNext);

    /**
     * Emitted when resolving a question
     */
    event Resolve(bytes32 indexed questionId, uint256 answerPrev, uint256 answerNext);

    /**
     * Emitted when finalising the resolution
     */
    event Finalise(bytes32 indexed questionId, uint256 answer);

    /**
     * Emitted when manually finalising a question
     */
    event ManuallyFinalise(bytes32 indexed questionId, uint256 answer);

    /* FortyTwo Market Activities (Trading & Claiming) */

    /**
     * Indexers please use this to maintain a user ledger via single-entry accounting (+outcome -collateral)
     * Please reconcile values using an RPC call & block tag
     *
     * Mint comes from protocol terminology: mint => user buys OTs from pool using collateral
     * Swap is added because Mint is conflicts with the "typical" Mint event
     */
    event MintSwap(
        address indexed caller,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 collateralFromUser,
        uint256 otToUser,
        uint256 collateralToTreasury
    );

    /**
     * Indexers please use this to maintain a user ledger via single-entry accounting (-outcome +collateral)
     * Please reconcile values using an RPC call & block tag
     *
     * Redeem comes from protocol terminology: redeem => user sells OTs from pool to get collateral
     * Swap is added because <refer to MintSwap>
     */
    event RedeemSwap(
        address indexed caller,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 collateralToUser,
        uint256 otToPool,
        uint256 collateralToTreasury
    );

    /**
     * Indexers please use this to maintain a user ledger via single-entry accounting (-outcome +collateral)
     * Please reconcile values using an RPC call & block tag
     *
     * Claiming is a similar financial transaction as redeem when viewed as a bookkeeper just that it has no fees (fee = 0).
     */
    event ClaimPayout(
        address indexed caller, address indexed receiver, uint256 indexed tokenId, uint256 otBurned, uint256 payout
    );

    /**
     * Emitted when setting the fee of a market
     *
     * @dev this event is a legacy event and there is no longer a per-market fee. Use SetProtocolFeeRate and SetProtocolFeeOverride instead.
     */
    event SetFeeRate(address indexed market, uint256 feeRate);

    /**
     * Emitted when setting treasury address
     */
    event SetTreasury(address indexed market);

    /**
     * Emitted when pausing trading.
     * Only trading can be paused. All markets will be paused.
     */
    event Paused(address account);

    /**
     * Emitted when unpausing. All markets will be unpaused.
     */
    event Unpaused(address account);

    /**
     * Emitted when creating a new question (timestampPrev is 0) or modifying the end timestamp of an existing market
     *
     * Please use this as a single source of truth/a ledger of amendments to the end timestamp, instead of attempting to track end timestamp via multiple possible event sources.
     * Please reconcile by identifying missing timestamps between timestampPrev & timestampNext. All questions must have exactly one event where timestampPrev is 0.
     *
     * @dev the naming can be slightly confusing due to differing versions:
     * In this version, end timestamp can be modified earlier to support markets whereby the market itself is a parlay (i.e P(A|B)).
     */
    event ModifyEnd(bytes32 indexed questionId, uint96 timestampPrev, uint96 timestampNext);

    /**
     * Emitted when setting a new default protocol fee rate
     */
    event SetProtocolFeeRate(uint80 feeRateNew);

    /**
     * Emitted when setting the fee rate of a specific market
     */
    event SetProtocolFeeOverride(address indexed market, uint80 feeRate, bool isOverride);

    /**
     * Emitted when creating new question
     *
     * @dev this replaces CreateNewQuestion
     */
    event CreateNewQuestionV2(
        bytes32 indexed questionId,
        address indexed oracle,
        address indexed creator,
        string title,
        string imageUri,
        uint96 timestampEnd,
        string[] outcomeNames,
        string[] outcomeImageUris,
        bytes ancillaryData
    );

    /**
     * Emitted when image URI for outcomes is updated
     */
    event OutcomeImageUpdated(bytes32 indexed questionId, uint256 indexOutcomeFromZero, string imageUri);

    /**
     * Emitted when image URI for question is updated
     */
    event QuestionImageUpdated(bytes32 indexed questionId, string imageUri);

    /**
     * Emitted when ancillary data is appended. This includes the initial ancillary data
     */
    event AncillaryDataUpdated(bytes32 indexed questionId, address indexed owner, bytes update);

    /**
     * Emitted when a question is flagged by an admin for manual finalisation
     *
     * @dev Similar in theory to uma-ctf-adaptor
     */
    event QuestionFlagged(bytes32 indexed questionId, uint96 timestampFlagExpiry);

    /**
     * Emitted when a question is unflagged by an admin
     *
     * @dev Similar in theory to uma-ctf-adaptor
     */
    event QuestionUnflagged(bytes32 indexed questionId);

    /**
     * Emitted when whitelisting a collateral
     */
    event CollateralWhitelist(address indexed collateral, bool isWhitelisted, uint256 collateralSeedMin);

    /**
     * Emitted when whitelisting a curve
     */
    event CurveWhitelist(address indexed curve, bool isWhitelisted);

    /**
     * Indexers please use this to maintain a user ledger via single-entry accounting (+outcome -collateral)
     * Please reconcile values using an RPC call & block tag
     *
     * Mint comes from protocol terminology: mint => user buys OTs from pool using collateral
     * Swap is added because Mint is conflicts with the "typical" Mint event
     *
     * @dev this replaces MintSwap
     */
    event MintSwapV2(
        address indexed caller,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 collateralToPool,
        uint256 otToUser,
        uint256 collateralToTreasury
    );

    /**
     * Indexers please use this to maintain a user ledger via single-entry accounting (-outcome +collateral)
     * Please reconcile values using an RPC call & block tag
     *
     * Redeem comes from protocol terminology: redeem => user sells OTs from pool to get collateral
     * Swap is added because <refer to MintSwapV2>
     *
     * @dev this replaces RedeemSwap
     */
    event RedeemSwapV2(
        address indexed caller,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 collateralFromPool,
        uint256 otToPool,
        uint256 collateralToTreasury
    );

    /**
     * Emitted by router when an integrator fee is charged on a mint.
     * Integrator fee is always charged in collateral.
     */
    event MintIntegratorFee(
        address indexed caller,
        address indexed integrator,
        address market,
        uint256 tokenId,
        uint256 collateralFromUser,
        uint256 collateralToIntegrator
    );

    /**
     * Emitted by router when an integrator fee is charged on a redeem.
     * Integrator fee is always charged in collateral.
     */
    event RedeemIntegratorFee(
        address indexed caller,
        address indexed integrator,
        address market,
        uint256 tokenId,
        uint256 collateralToUser,
        uint256 collateralToIntegrator
    );

    /**
     * Emitted by dispute registry when a dispute is raised.
     * Does not include a snapshot of the answer as current answer is mutable and can re-resolve.
     */
    event DisputeAncillaryDataUpdated(
        bytes32 indexed questionId, address indexed owner, uint256 answerProposed, bytes update
    );
}
