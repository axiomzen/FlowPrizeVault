# Projected User Balance — Implementation Spec

## Overview

Currently, querying a user's balance via `getUserAssetValue()` returns a value based on the **last synced** share price. Between syncs, yield accrues in the yield source but isn't reflected in the user's displayed balance. This spec adds **view-only preview functions** that calculate what the balance *would be* if a sync happened right now — enabling real-time balance display without mutating state.

This is a **contract upgrade** (additive only — new view functions on existing resources). No redeployment required.

## Changes

### 1. `ShareTracker.previewAccrueYield(amount: UFix64): UFix64`

Pure calculation that returns the effective rewards amount after subtracting virtual-share dust. Mirrors the math inside `accrueYield()` but without mutation.

```cadence
access(all) view fun previewAccrueYield(amount: UFix64): UFix64 {
    if amount == 0.0 || self.totalShares == 0.0 {
        return 0.0
    }
    let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
    let dustAmount = amount * PrizeLinkedAccounts.VIRTUAL_SHARES / effectiveShares
    return amount - dustAmount
}
```

### 2. Refactor `ShareTracker.accrueYield()` to delegate

Eliminates duplicated dust math by reusing `previewAccrueYield`.

```cadence
access(contract) fun accrueYield(amount: UFix64): UFix64 {
    let actualRewards = self.previewAccrueYield(amount: amount)
    if actualRewards == 0.0 {
        return 0.0
    }
    self.totalAssets = self.totalAssets + actualRewards
    self.totalDistributed = self.totalDistributed + actualRewards
    return actualRewards
}
```

### 3. `Pool.previewDeficitImpactOnRewards(deficitAmount: UFix64): UFix64`

Pure calculation of how much of a deficit would cascade through to the rewards pool (reducing share price). Mirrors the deficit waterfall: protocol fee absorbed first, then prize pool, then rewards.

```cadence
access(self) view fun previewDeficitImpactOnRewards(deficitAmount: UFix64): UFix64 {
    var remaining = deficitAmount

    // Protocol fee absorbs first
    let absorbedByProtocol = remaining < self.allocatedProtocolFee
        ? remaining : self.allocatedProtocolFee
    remaining = remaining - absorbedByProtocol

    // Prize pool absorbs second
    let absorbedByPrize = remaining < self.allocatedPrizeYield
        ? remaining : self.allocatedPrizeYield
    remaining = remaining - absorbedByPrize

    // Whatever remains hits rewards (share price)
    return remaining
}
```

### 4. `Pool.getProjectedUserBalance(receiverID: UInt64): UFix64`

View function that returns a user's projected balance accounting for unsync'd yield or deficit.

```cadence
access(all) fun getProjectedUserBalance(receiverID: UInt64): UFix64 {
    let userShares = self.shareTracker.getUserShares(receiverID: receiverID)
    if userShares == 0.0 {
        return 0.0
    }

    // Compare yield source balance to what we've already accounted for
    let yieldBalance = self.config.yieldConnector.minimumAvailable()
    let allocatedFunds = self.getTotalAllocatedFunds()
    let difference: UFix64 = yieldBalance > allocatedFunds
        ? yieldBalance - allocatedFunds
        : allocatedFunds - yieldBalance

    // If difference is below dust threshold, just return current balance
    if difference < PrizeLinkedAccounts.MINIMUM_DISTRIBUTION_THRESHOLD {
        return self.shareTracker.getUserAssetValue(receiverID: receiverID)
    }

    var projectedTotalAssets = self.shareTracker.getTotalAssets()
    let totalShares = self.shareTracker.getTotalShares()

    if yieldBalance > allocatedFunds {
        // Excess yield — preview the distribution split
        let plan = self.config.distributionStrategy.calculateDistribution(
            totalAmount: difference
        )
        // Only the rewards portion increases share price
        let projectedRewards = self.shareTracker.previewAccrueYield(
            amount: plan.rewardsAmount
        )
        projectedTotalAssets = projectedTotalAssets + projectedRewards
    } else {
        // Deficit — preview the waterfall impact on rewards
        let deficitToRewards = self.previewDeficitImpactOnRewards(
            deficitAmount: difference
        )
        projectedTotalAssets = projectedTotalAssets > deficitToRewards
            ? projectedTotalAssets - deficitToRewards
            : 0.0
    }

    // Compute projected share price with virtual offset
    let effectiveShares = totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
    let effectiveAssets = projectedTotalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS
    let projectedSharePrice = effectiveAssets / effectiveShares

    return userShares * projectedSharePrice
}
```

### 5. Contract-level convenience function

```cadence
access(all) fun getProjectedUserBalance(poolID: UInt64, receiverID: UInt64): UFix64 {
    if let poolRef = self.borrowPool(poolID: poolID) {
        return poolRef.getProjectedUserBalance(receiverID: receiverID)
    }
    return 0.0
}
```

## How it works

```
Yield Source Balance (real)          e.g. 102.50
- Total Allocated Funds (tracked)   e.g. 100.00
= Unsynced Difference               e.g.   2.50

If excess (yield source > allocated):
  → distributionStrategy.calculateDistribution(2.50)
    → rewardsAmount (e.g. 0.875 at 35%)
    → previewAccrueYield(0.875) → effective rewards after dust
    → projectedTotalAssets += effective rewards

If deficit (yield source < allocated):
  → previewDeficitImpactOnRewards(deficit)
    → protocol fee absorbs first, then prize, then rewards
    → projectedTotalAssets -= remaining deficit

Projected share price = (projectedTotalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
Projected user balance = userShares * projectedSharePrice
```

## Notes

- All functions are `view` — no state mutation, safe for scripts
- `previewAccrueYield` is reused by both the mutating `accrueYield` and the read-only `getProjectedUserBalance`, eliminating duplicated dust math
- The deficit waterfall preview mirrors `applyDeficit()` logic without mutation
- `MINIMUM_DISTRIBUTION_THRESHOLD` check prevents unnecessary computation for negligible differences
- This is an **additive upgrade** — no existing fields or signatures change
