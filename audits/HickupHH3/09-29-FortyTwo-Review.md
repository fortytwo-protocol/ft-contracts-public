# Gist Link
[Gist Link](https://gist.github.com/HickupHH3/a8209db94386cb70ab6637c0f8032fbe) 

# Table of Contents
- [Table of Contents](#table-of-contents)
  - [🟢 \[LOW\] Funds aren't swept when no one wins](#-low-funds-arent-swept-when-no-one-wins)
    - [Context](#context)
    - [Description](#description)
    - [POC](#poc)
    - [Recommendation](#recommendation)
    - [Status](#status)
  - [🔵 \[INFO\] Redundant `getState()` function](#-info-redundant-getstate-function)
    - [Context](#context-1)
    - [Description \& Recommendation](#description--recommendation)
    - [Status](#status-1)
  - [🔵 \[INFO\] Incorrect comments](#-info-incorrect-comments)
    - [Context](#context-2)
    - [Description \& Recommendation](#description--recommendation-1)
    - [Status](#status-2)
  - [🔵 \[INFO\] Consider making the router's `onMint()` callback permissioned](#-info-consider-making-the-routers-onmint-callback-permissioned)
    - [Context](#context-3)
    - [Description \& Recommendation](#description--recommendation-2)
    - [Status](#status-3)
  - [🔵 \[INFO\] Sanity check the `tokenId` in `name()` and `symbol()`](#-info-sanity-check-the-tokenid-in-name-and-symbol)
    - [Context](#context-4)
    - [Description](#description-1)
    - [Recommendation](#recommendation-1)
    - [Status](#status-4)
  - [🟣 \[GAS\] Directly modifying array lengths avoids need for temporary arrays](#-gas-directly-modifying-array-lengths-avoids-need-for-temporary-arrays)
    - [Context](#context-5)
    - [Description](#description-2)
    - [Recommendation](#recommendation-2)
    - [Status](#status-5)
  - [🟣 \[GAS\] Math libraries' optimizations](#-gas-math-libraries-optimizations)
    - [Context](#context-6)
    - [Description \& Recommendation](#description--recommendation-3)
    - [Status](#status-6)
  - [🟣 \[GAS\] Encode direct ERC20 `transferFrom()` for ERC20 collateral transfers](#-gas-encode-direct-erc20-transferfrom-for-erc20-collateral-transfers)
    - [Context](#context-7)
    - [Description](#description-3)
    - [Recommendation](#recommendation-3)
    - [Status](#status-7)
  - [🟣 \[GAS\] Duplicate checks in `claim()` and `_claim()`.](#-gas-duplicate-checks-in-claim-and-_claim)
    - [Context](#context-8)
    - [Description](#description-4)
    - [Recommendation](#recommendation-4)
    - [Status](#status-8)

## 🟢 [LOW] Funds aren't swept when no one wins

### Context
- [FTMarket.sol#L318-L323](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTMarket.sol#L318-L323)

### Description
The zeroing of `totalMarketCap` is done before the instantiation of `excess`, so `excess` is zero, resulting in no funds being swept to the treasury, although it can be subsequently transferred by calling `skim()`. 

### POC
```solidity
function test_noOneWins() public {
  _userMint(USER1, Market.toTokenId(0), 100 * FTMath.FT_ONE);
  _userMint(USER1, Market.toTokenId(1), 100 * FTMath.FT_ONE);
  _userMint(USER1, Market.toTokenId(2), 100 * FTMath.FT_ONE);

  // add a new outcome
  vm.prank(CREATOR);
  string[] memory newOutcome = new string[](1);
  newOutcome[0] = "New Outcome";
  controller.addOutcomes(questionId, newOutcome);

  // resolve to new outcome
  vm.prank(RESOLVER);
  controller.resolveOutcome(questionId, 8); // 8 = 0b1000

  // finalise outcome
  vm.prank(FINALISER);
  controller.finaliseOutcome(questionId, 8);

  // claim, check that user gets nothing
  uint256 treasuryCollateralBefore = collateral.balanceOf(TREASURY);
  uint256 totalMarketCap = market.totalMarketCap();
  vm.prank(USER1);
  uint256[] memory tokenIds = new uint256[](3);
  tokenIds[0] = Market.toTokenId(0);
  tokenIds[1] = Market.toTokenId(1);
  tokenIds[2] = Market.toTokenId(2);
  uint256 payout = market.claim(USER1, tokenIds, _buildClaimAllOtAmounts(USER1, tokenIds), EMPTY_BYTES);
  assertEq(payout, 0, "user should get nothing");

  // check that market cap has been zeroed
  assertEq(market.totalMarketCap(), 0, "market cap should be zero");
  // and all collateral has gone to the treasury
  assertEq(collateral.balanceOf(TREASURY), treasuryCollateralBefore + totalMarketCap, "all collateral should have gone to the treasury");
}
```

### Recommendation
```diff
diff --git a/src/FTMarket.sol b/src/FTMarket.sol
index 224f63f..a846313 100644
--- a/src/FTMarket.sol
+++ b/src/FTMarket.sol
@@ -316,9 +316,9 @@ contract FTMarket is IFTMarket, FTERC6909, TokenHelper, ReentrancyGuard, HasFTEv
 
         // very awkward edge case: somehow no one holds the winners -> send to treasury and think about how to redistribute
         if (otSupplyWinning == 0 && market.totalMarketCap > 1) {
+            excess = market.totalMarketCap;
             market.totalMarketCap = 0;
             payout = 0;
-            excess = market.totalMarketCap;
             return (payout, excess);
         }

```

### Status
Fixed in [PR #13](https://github.com/fortytwo-protocol/ft-contracts/pull/13).

## 🔵 [INFO] Redundant `getState()` function

### Context
- [Registry.sol#L129-L131](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/controller/mixins/Registry.sol#L129-L131)

### Description & Recommendation
Unused function, can be removed.

### Status
Fixed in [PR #8](https://github.com/fortytwo-protocol/ft-contracts/pull/8).

## 🔵 [INFO] Incorrect comments

### Context
- [Registry.sol#L12](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/controller/mixins/Registry.sol#L12)
- [BBLSMath.sol#L110](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLSMath.sol#L110)
- [FTRouter.sol#L18](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTRouter.sol#L18)

### Description & Recommendation

```diff
- // eg, num of outcomes = 3, outcome of 4 = 0b100 (binary), this means the first option is the correct outcome
+ // eg, num of outcomes = 3, outcome of 4 = 0b100 (binary), this means the third option is the correct outcome

- // term1 = (x-c1)/(c2a*(c3 + (x-c1)/c2b)^2)^(1/2))
+ // term1 = (x-c1)/(c2a*(c3 + ((x-c1)/c2b)^2)^(1/2))

- inititator
+ initiator
```

### Status
Fixed in [PR #9](https://github.com/fortytwo-protocol/ft-contracts/pull/9).

## 🔵 [INFO] Consider making the router's `onMint()` callback permissioned

### Context
- [FTRouter.sol#L25-L48](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTRouter.sol#L25-L48)

### Description & Recommendation
The `FTRouter` has a `onMint()` callback that is permissionless. While no attack vector was discovered, it is recommended to restrict calls to deployed markets via the factory for safety.

### Status
Fixed in [PR #14](https://github.com/fortytwo-protocol/ft-contracts/pull/14).

## 🔵 [INFO] Sanity check the `tokenId` in `name()` and `symbol()`

### Context
- [FTMarket.sol#L449-L471](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTMarket.sol#L449-L471)

### Description
If an out-of-bounds `tokenId` is passed into the `name()` or `symbol()` functions, they will panic revert with the default indexOOB error.

### Recommendation
Add the `tokenId` range check that is present in `mintCollateralToOt()` / `redeemOtToCollateral()`.
```solidity
if (tokenId == 0 || tokenId > toTokenId(self.numOutcomes - 1)) revert Errors.MarketInvalidTokenId(tokenId);
```

### Status
Fixed in [PR #16](https://github.com/fortytwo-protocol/ft-contracts/pull/16).

## 🟣 [GAS] Directly modifying array lengths avoids need for temporary arrays

### Context
- [ActionSimple.sol#L101-L119](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/router/ActionSimple.sol#L101-L119)

### Description
By directly modifying the lengths of the `tokenIdsTemp` and `otToBurnTemp` arrays in assembly, copying the elements into the actual result arrays can be avoided.

### Recommendation
```diff
diff --git a/src/router/ActionSimple.sol b/src/router/ActionSimple.sol
index da18768..94f5f3b 100644
--- a/src/router/ActionSimple.sol
+++ b/src/router/ActionSimple.sol
@@ -98,24 +98,23 @@ contract ActionSimple is TokenHelper {
 
         if (answer == 0 || !isFinalised) revert Errors.RouterNotClaimableYet();
         uint256 counter = 0;
-        uint256[] memory tokenIdsTemp = new uint256[](numOutcomes);
-        uint256[] memory otToBurnTemp = new uint256[](numOutcomes);
+        uint256[] memory tokenIds = new uint256[](numOutcomes);
+        uint256[] memory otToBurn = new uint256[](numOutcomes);
         for (uint256 i = 0; i < numOutcomes; ++i) {
             uint256 tokenId = Market.toTokenId(i);
             if (Market.isWinner(answer, tokenId)) {
                 uint256 otBalance = IFTMarket(market).balanceOf(msg.sender, tokenId);
-                tokenIdsTemp[counter] = tokenId;
-                otToBurnTemp[counter] = otBalance;
+                tokenIds[counter] = tokenId;
+                otToBurn[counter] = otBalance;
                 _transferIn(market, tokenId, msg.sender, otBalance);
                 counter++;
             }
         }
 
-        uint256[] memory tokenIds = new uint256[](counter);
-        uint256[] memory otToBurn = new uint256[](counter);
-        for (uint256 i = 0; i < counter; ++i) {
-            tokenIds[i] = tokenIdsTemp[i];
-            otToBurn[i] = otToBurnTemp[i];
+        // adjust length of arrays to counter
+        assembly ("memory-safe") {
+            mstore(tokenIds, counter)
+            mstore(otToBurn, counter)
         }
 
         payout = IFTMarket(market).claim(receiver, tokenIds, otToBurn, EMPTY_BYTES);

```

### Status
Fixed in [PR #7](https://github.com/fortytwo-protocol/ft-contracts/pull/7).

## 🟣 [GAS] Math libraries' optimizations

### Context
- [BBLBMath.sol#L28](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLBMath.sol#L28)
- [BBLBMath.sol#L30](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLBMath.sol#L30)
- [BBLSMath.sol#L161-L162](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLSMath.sol#L161-L162)
- [BBLSMath.sol#L121](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLSMath.sol#L121)
- [BBLSMath.sol#L62-L103](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/curves/math/BBLSMath.sol#L62-L103)

### Description & Recommendation

```solidity
uint256 c1Plus1ExponentScaled = c1Plus1.fullMulDiv(LogExpMath.UONE_18, FTMath.FT_ONE);
```
Not sure if the scaling is done correctly, if it's needed at all, since `UONE_18` == `FT_ONE` == `1e18`. If redundant, then can use `c1Plus1` directly.

---

```diff
- uint256 term2 = outcomeAmount.fullMulDiv(outcomeAmount, FTMath.FT_ONE).fullMulDiv(FTMath.FT_ONE, 2 * self.c2);
+ uint256 term2 = outcomeAmount.fullMulDiv(outcomeAmount, 2 * self.c2);

- uint256 numerator = c2bSquared.fullMulDiv(sqrtC3PlusRatioSquared, FTMath.FT_ONE);
- uint256 result = numerator.fullMulDiv(FTMath.FT_ONE, self.c2a);
+ uint256 result = c2bSquared.fullMulDiv(sqrtC3PlusRatioSquared, self.c2a);
```

---

1. Use `mulSqrt()` in case of multiplication overflow.
2. The comment `// sqrt halves decimals, so scale input by double the decimals!` is sort of misleading, because the decimals is scaled when multiplying with `1e18` and square rooted. Recommend removing.

```diff
- uint256 sqrtC3PlusRatioSquared = ((ratioSquared + self.c3) * FTMath.FT_ONE).sqrt();
+ uint256 sqrtC3PlusRatioSquared = (ratioSquared + self.c3).mulSqrt(FTMath.FT_ONE);
```

---

1. `BBLSMath.calCost()` can be simplified as its terms are all positive.
2. The subtraction underflow check should be done for `BBLSMath.calMarginalPrice()` instead.
```solidity
require(positiveSum >= negativeSum, "overflow hit!");
```

### Status
Fixed in [PR #10](https://github.com/fortytwo-protocol/ft-contracts/pull/10).

## 🟣 [GAS] Encode direct ERC20 `transferFrom()` for ERC20 collateral transfers

### Context
- [ActionSimple.sol#L173](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/router/ActionSimple.sol#L173)

### Description
The ERC20 only transfer method can be used instead of generalised ERC20 / ERC6909 transfer for ERC20 collaterals, which should be the bulk of the markets.

### Recommendation
```diff
diff --git a/src/router/ActionSimple.sol b/src/router/ActionSimple.sol
index 0025dc9..98d300f 100644
--- a/src/router/ActionSimple.sol
+++ b/src/router/ActionSimple.sol
@@ -169,7 +169,9 @@ contract ActionSimple is TokenHelper {
             tokenId,
             otOut,
             dataSwap,
-            Fedec.encodeTransferFromInitiator(params.collateral, params.parentTokenId, address(this))
+            params.parentTokenId == NULL_PARENT_ID ? 
+                Fedec.encodeERC20TransferFromInitiator(params.collateral, address(this)) :
+                Fedec.encodeTransferFromInitiator(params.collateral, params.parentTokenId, address(this))
         );
         _forceApprove(params.collateral, params.parentTokenId, market, 0);
     }
     
```

### Status
Fixed in [PR #12](https://github.com/fortytwo-protocol/ft-contracts/pull/12).

## 🟣 [GAS] Duplicate checks in `claim()` and `_claim()`.

### Context
- [FTMarket.sol#L173-L176](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTMarket.sol#L173-L176)
- [FTMarket.sol#L313-L315](https://github.com/fortytwo-protocol/ft-contracts/blob/16a9dfc76025264cb1eaea6de61fcb1c67cfcfe0/src/FTMarket.sol#L313-L315)

### Description
The following checks are duplicated in the `claim()` and `_claim()` functions:
```solidity
if (!market.isFinalised) revert Errors.MarketNotFinalised();
if (market.answer == 0) revert Errors.MarketUnprocessableAnswer(market.answer);
if (market.answer >= (1 << market.numOutcomes)) revert Errors.MarketTooManyOutcomes();
```

### Recommendation
Remove a set of these checks in either function.

### Status
Fixed in [PR #15](https://github.com/fortytwo-protocol/ft-contracts/pull/15).