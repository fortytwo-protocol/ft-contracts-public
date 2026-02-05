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
        uint256 collateralToPool,
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

    /* FortyTwo Governance Related */

    /**
     * Emitted when setting the fee of a market
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
}
