// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library Errors {
    error FactoryInvalidCurve();
    error FactoryInvalidCollateral();
    error FactoryInvalidSeedAmount();
    error FactoryUnsuccessfulMarketDeployment();
    error FactoryFeeRateExceedMaximumLimit();

    error CurveInvalidCost(uint256 quantity);
    error CurveOtDeltaNotOnTick(uint256 otDelta, uint256 tick);

    error RegistryInsufficientOutcomesGiven();
    error RegistryExceedMaxNames();
    error RegistryAlreadyRegistered();
    error RegistryInvalidAddressPtr();
    error RegistryEndTimestampHasPassed();
    error RegistryEmptyTitle();
    error RegistryExceedMaxTitleLength();
    error RegistryExceedMaxDescriptionLength();
    error RegistryEmptyName();
    error RegistryExceedMaxNameLength();
    error RegistryDuplicateOutcome();
    error RegistryNotRegistered();
    error RegistryAlreadyFinalised();
    error RegistryEndTimestampBeforeExisting();
    error RegistryInvalidAnswer();
    error RegistrySameAnswer();
    error RegistryNotResolved();
    error RegistryAnswerDoesNotMatchCurrent();
    error Registry6909MustBeRegisteredMarket();
    error RegistryInvalidTokenIdAsCollateral();
    error RegistryTokenIdNotCreatedForMarket();
    error RegistryInvalidTreasuryAddress();

    error GuessInvalidDataLength(uint256 len, uint256 required);
    error GuessMinGreaterThanMax(uint256 guessMin, uint256 guessMax);
    error GuessMaxIterationsZero();
    error GuessEpsAboveMax();
    error GuessExceedMaxIterations(uint256 maxIterations);
    error GuessExceedMaxInterpolationIterations(uint256 maxIterations);
    error GuessTargetUnreachable(uint256 current, uint256 target);

    error MarketUnprocessableAnswer(uint256 answer);
    error MarketPayoutPerOutcomeAlreadyCalculated(uint256 payoutPerOutcome);
    error MarketNotFinalised();
    error MarketNotResolved();
    error MarketSwapAmountCannotBeZero();
    error MarketTooManyTotalSupplies(uint256 required);
    error MarketTooManyOutcomes();
    error MarketNotStarted();
    error MarketEnded();
    error MarketResolved();
    error MarketUnauthorizedAccess(address account, address required);
    error MarketZeroCostBasis();
    error MarketInvalidTokenId(uint256 tokenId);
    error MarketSwapPriceInvalidated(uint256 collateralDelta, uint256 otDelta);
    error MarketArrayLengthsMismatch();
    error MarketNoClaim();
    error MarketPaused();
    error MarketNotWhole();
    error MarketReceiverIsMarket();
    error MarketZeroAddress();

    error RouterUnauthorized();
    error RouterDbCViolated();
    error RouterSlippage();
    error RouterUnsupportedSelector();
    error RouterArrayLengthsMismatch();
    error RouterNotClaimableYet();
}
