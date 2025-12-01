# Time-Weighted Average Balance (TWAB)

This document provides an in-depth explanation of the Time-Weighted Average Balance (TWAB) mechanism used in PrizeSavings to ensure fair lottery odds.

## Table of Contents

- [Overview](#overview)
- [Why TWAB?](#why-twab)
- [Core Concepts](#core-concepts)
- [Mathematical Foundation](#mathematical-foundation)
- [Implementation Details](#implementation-details)
- [Epoch System](#epoch-system)
- [Bonus Weights](#bonus-weights)
- [Examples](#examples)
- [Edge Cases](#edge-cases)
- [Integration with Lottery](#integration-with-lottery)

---

## Overview

TWAB (Time-Weighted Average Balance) is a mechanism that calculates a user's lottery odds based on both:

1. **How much** they have deposited (balance)
2. **How long** they have held that balance (time)

This prevents manipulation where users could deposit large amounts just before a draw to gain unfair odds, then immediately withdraw afterward.

---

## Why TWAB?

### The Problem with Snapshot-Based Systems

In a naive lottery system, odds might be calculated at a single moment (snapshot):

```
User A: 100 tokens → 50% odds
User B: 100 tokens → 50% odds
```

**Attack vector**: A whale could:
1. Watch for an upcoming draw
2. Deposit 10,000 tokens seconds before the snapshot
3. Win with ~99% odds
4. Withdraw immediately after

### The TWAB Solution

TWAB integrates balance over time, measuring **share-seconds**:

```
User A: 100 tokens for 7 days  = 100 × 604,800 = 60,480,000 share-seconds
User B: 10,000 tokens for 1 hour = 10,000 × 3,600 = 36,000,000 share-seconds

User A odds: 60,480,000 / 96,480,000 ≈ 62.7%
User B odds: 36,000,000 / 96,480,000 ≈ 37.3%
```

Despite having 100x the balance, User B's late entry gives them lower odds than User A's long-term holding.

---

## Core Concepts

### Share-Seconds

The fundamental unit of TWAB measurement:

```
share-seconds = shares × seconds_held
```

Where `shares` represents the user's proportional ownership in the pool (see [ERC4626 shares model](./SHARES.md)).

### Cumulative Tracking

Rather than storing historical balances, we track:

```
cumulativeShareSeconds = Σ(shares × time_at_each_balance)
```

This is updated incrementally whenever a user's balance changes.

### Epochs

Each lottery draw period is an **epoch**. TWAB resets at the start of each epoch to ensure:
- Previous draws don't affect current odds
- Users start fresh each period
- Memory usage stays bounded

---

## Mathematical Foundation

### Basic Formula

For a user with constant shares over a time period:

```
timeWeightedStake = shares × (currentTime - lastUpdateTime)
```

### With Balance Changes

When a user's share balance changes, we:

1. **Accumulate** the share-seconds up to now
2. **Update** the timestamp
3. **Continue** tracking from the new balance

```
newAccumulated = oldAccumulated + (oldShares × timeSinceLastUpdate)
lastUpdateTime = now
```

### Total User Weight at Draw Time

```
totalWeight = cumulativeShareSeconds + elapsedSinceLastUpdate
           = accumulated + (currentShares × (drawTime - lastUpdateTime))
```

### Lottery Odds

A user's probability of winning:

```
P(win) = userTimeWeightedStake / Σ(allUsersTimeWeightedStakes)
```

---

## Implementation Details

### State Variables

```cadence
resource SavingsDistributor {
    // Per-user TWAB tracking
    access(self) let userCumulativeShareSeconds: {UInt64: UFix64}
    access(self) let userLastUpdateTime: {UInt64: UFix64}
    access(self) let userEpochID: {UInt64: UInt64}
    
    // Global epoch tracking
    access(self) var currentEpochID: UInt64
    access(self) var epochStartTime: UFix64
}
```

### Key Functions

#### `getElapsedShareSeconds(receiverID)` — View Function

Calculates share-seconds elapsed since last update, handling epoch staleness:

```cadence
access(all) view fun getElapsedShareSeconds(receiverID: UInt64): UFix64 {
    let now = getCurrentBlock().timestamp
    let userEpoch = self.userEpochID[receiverID] ?? 0
    let currentShares = self.userShares[receiverID] ?? 0.0
    
    // If epoch is stale, calculate from epoch start (as if reset happened)
    let effectiveLastUpdate = userEpoch < self.currentEpochID 
        ? self.epochStartTime 
        : (self.userLastUpdateTime[receiverID] ?? self.epochStartTime)
    
    let elapsed = now - effectiveLastUpdate
    if elapsed <= 0.0 {
        return 0.0
    }
    return currentShares * elapsed
}
```

#### `accumulateTime(receiverID)` — Mutating Function

Updates the cumulative tracking state:

```cadence
access(contract) fun accumulateTime(receiverID: UInt64) {
    let userEpoch = self.userEpochID[receiverID] ?? 0
    
    // Lazy reset for stale epoch
    if userEpoch < self.currentEpochID {
        self.userCumulativeShareSeconds[receiverID] = 0.0
        self.userLastUpdateTime[receiverID] = self.epochStartTime
        self.userEpochID[receiverID] = self.currentEpochID
    }
    
    // Get elapsed share-seconds and add to accumulated
    let elapsed = self.getElapsedShareSeconds(receiverID: receiverID)
    if elapsed > 0.0 {
        let currentAccum = self.userCumulativeShareSeconds[receiverID] ?? 0.0
        self.userCumulativeShareSeconds[receiverID] = currentAccum + elapsed
        self.userLastUpdateTime[receiverID] = getCurrentBlock().timestamp
    }
}
```

#### `getTimeWeightedStake(receiverID)` — View Function

Returns total TWAB without mutating state:

```cadence
access(all) view fun getTimeWeightedStake(receiverID: UInt64): UFix64 {
    return self.getEffectiveAccumulated(receiverID: receiverID) 
        + self.getElapsedShareSeconds(receiverID: receiverID)
}
```

#### `updateAndGetTimeWeightedStake(receiverID)` — Mutating Function

Used during draws to finalize and snapshot TWAB:

```cadence
access(contract) fun updateAndGetTimeWeightedStake(receiverID: UInt64): UFix64 {
    self.accumulateTime(receiverID: receiverID)
    return self.userCumulativeShareSeconds[receiverID] ?? 0.0
}
```

---

## Epoch System

### Purpose

Epochs bound the TWAB accumulation to discrete lottery periods:

- **Epoch N**: Accumulate TWAB from draw N-1 to draw N
- **Draw N**: Snapshot all TWAB values, select winner
- **Epoch N+1**: Reset all TWAB, start fresh accumulation

### Epoch Transitions

When `startDraw()` is called:

1. All user TWABs are finalized via `updateAndGetTimeWeightedStake()`
2. Values are snapshotted into the `PrizeDrawReceipt`
3. `startNewPeriod()` increments `currentEpochID` and resets `epochStartTime`
4. Users' TWAB effectively resets (via lazy evaluation on next interaction)

```cadence
access(contract) fun startNewPeriod() {
    self.currentEpochID = self.currentEpochID + 1
    self.epochStartTime = getCurrentBlock().timestamp
}
```

### Lazy Reset

Users don't need to explicitly reset—when they interact after an epoch change:

```cadence
if userEpoch < self.currentEpochID {
    self.userCumulativeShareSeconds[receiverID] = 0.0
    self.userLastUpdateTime[receiverID] = self.epochStartTime
    self.userEpochID[receiverID] = self.currentEpochID
}
```

This lazy approach is gas-efficient: we only update users who actually participate.

---

## Bonus Weights

Admins can grant bonus lottery weights for promotions or rewards:

```cadence
access(self) let receiverBonusWeights: {UInt64: BonusWeightRecord}

struct BonusWeightRecord {
    let bonusWeight: UFix64   // Additional weight per second
    let reason: String        // Why bonus was granted
    let addedAt: UFix64       // When bonus was set
    let addedBy: Address      // Who set it
}
```

### Bonus Scaling

Bonuses are **time-scaled** like regular TWAB to prevent gaming:

```cadence
let bonusWeight = self.getBonusWeight(receiverID: receiverID)
let epochDuration = getCurrentBlock().timestamp - self.savingsDistributor.getEpochStartTime()
let scaledBonus = bonusWeight * epochDuration

let totalStake = twabStake + scaledBonus
```

A bonus of `1.0` held for the full epoch adds `epochDuration` share-seconds to the user's weight.

### Admin Functions

```cadence
// Set absolute bonus weight
Admin.setBonusLotteryWeight(poolID, receiverID, bonusWeight, reason, setBy)

// Add to existing bonus
Admin.addBonusLotteryWeight(poolID, receiverID, additionalWeight, reason, addedBy)

// Remove all bonus
Admin.removeBonusLotteryWeight(poolID, receiverID, removedBy)
```

---

## Examples

### Example 1: Single User, Constant Balance

**Setup:**
- User A deposits 1000 tokens at epoch start
- Epoch duration: 7 days (604,800 seconds)
- No other users

**Calculation:**
```
shares = 1000 (assuming 1:1 initial ratio)
timeWeightedStake = 1000 × 604,800 = 604,800,000 share-seconds

Lottery odds = 100% (only participant)
```

### Example 2: Two Users, Different Entry Times

**Setup:**
- User A deposits 500 tokens at epoch start
- User B deposits 500 tokens at day 3
- Epoch duration: 7 days

**Calculation:**
```
User A:
  shares = 500
  time = 7 days = 604,800 seconds
  TWAB = 500 × 604,800 = 302,400,000

User B:
  shares = 500
  time = 4 days = 345,600 seconds
  TWAB = 500 × 345,600 = 172,800,000

Total = 475,200,000

User A odds: 302,400,000 / 475,200,000 = 63.6%
User B odds: 172,800,000 / 475,200,000 = 36.4%
```

Despite equal balances, User A has better odds due to longer holding time.

### Example 3: Balance Change Mid-Epoch

**Setup:**
- User A deposits 100 tokens at epoch start
- After 3 days, User A deposits 400 more tokens
- Epoch duration: 7 days

**Calculation:**
```
Phase 1 (days 0-3):
  shares = 100
  time = 3 days = 259,200 seconds
  accumulated = 100 × 259,200 = 25,920,000

Phase 2 (days 3-7):
  shares = 500 (100 original + 400 new)
  time = 4 days = 345,600 seconds
  additional = 500 × 345,600 = 172,800,000

Total TWAB = 25,920,000 + 172,800,000 = 198,720,000 share-seconds
```

### Example 4: Whale Attack Prevention

**Setup:**
- User A: 100 tokens for entire 7-day epoch
- Whale: 10,000 tokens deposited 1 hour before draw

**Calculation:**
```
User A:
  TWAB = 100 × 604,800 = 60,480,000

Whale:
  TWAB = 10,000 × 3,600 = 36,000,000

Total = 96,480,000

User A odds: 60,480,000 / 96,480,000 = 62.7%
Whale odds: 36,000,000 / 96,480,000 = 37.3%
```

The whale has 100x the balance but only 37.3% odds!

---

## Edge Cases

### User Deposits After Epoch Start, Never Interacts Again

The `getElapsedShareSeconds()` view function correctly calculates TWAB at draw time without requiring the user to call any function.

### User from Previous Epoch Doesn't Interact

Lazy reset handles this—their `userEpochID` is stale, so TWAB calculation uses epoch start time and returns 0 for accumulated.

### Zero Share Balance

If a user has no shares:
```cadence
let currentShares = self.userShares[receiverID] ?? 0.0
// ...
return currentShares * elapsed  // = 0.0 × elapsed = 0.0
```

### Overflow Protection

For extremely large pools or long epochs:
```cadence
// In convertToShares/convertToAssets
if assets > 0.0 && self.totalShares > 0.0 {
    let maxSafeAssets = UFix64.max / self.totalShares
    assert(assets <= maxSafeAssets, message: "Would cause overflow")
}
```

---

## Integration with Lottery

### Draw Flow

1. **`startDraw()` called:**
   ```cadence
   let timeWeightedStakes: {UInt64: UFix64} = {}
   for receiverID in self.registeredReceivers.keys {
       let twabStake = self.savingsDistributor.updateAndGetTimeWeightedStake(receiverID: receiverID)
       let bonusWeight = self.getBonusWeight(receiverID: receiverID)
       let epochDuration = getCurrentBlock().timestamp - self.savingsDistributor.getEpochStartTime()
       let scaledBonus = bonusWeight * epochDuration
       
       let totalStake = twabStake + scaledBonus
       if totalStake > 0.0 {
           timeWeightedStakes[receiverID] = totalStake
       }
   }
   ```

2. **Snapshot stored in receipt:**
   ```cadence
   let receipt <- create PrizeDrawReceipt(
       prizeAmount: prizeAmount,
       request: <- randomRequest,
       timeWeightedStakes: timeWeightedStakes  // Frozen snapshot
   )
   ```

3. **New epoch starts immediately:**
   ```cadence
   self.savingsDistributor.startNewPeriod()
   ```

4. **`completeDraw()` uses frozen snapshot:**
   ```cadence
   let timeWeightedStakes = unwrappedReceipt.getTimeWeightedStakes()
   let selectionResult = self.config.winnerSelectionStrategy.selectWinners(
       randomNumber: randomNumber,
       receiverDeposits: timeWeightedStakes,  // Uses snapshot, not live values
       totalPrizeAmount: totalPrizeAmount
   )
   ```

### Why Snapshot Between Blocks?

The commit-reveal pattern requires:
1. `startDraw()`: Commit to randomness source (future block)
2. Wait 1+ blocks
3. `completeDraw()`: Reveal randomness, select winner

The TWAB snapshot is taken at commit time, ensuring:
- Users can't manipulate odds after seeing randomness
- The exact weights used for selection are frozen
- Deposits/withdrawals between commit and reveal don't affect this draw

---

## Summary

TWAB provides provably fair lottery odds by:

1. **Measuring balance × time** instead of just balance
2. **Preventing last-minute manipulation** via time-weighting
3. **Using lazy evaluation** for gas efficiency
4. **Resetting each epoch** to keep draws independent
5. **Supporting bonus weights** that are also time-scaled
6. **Snapshotting at commit time** to prevent post-randomness manipulation

This creates a lottery system where consistent, long-term participants have proportionally fair odds compared to opportunistic large depositors.

