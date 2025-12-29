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

### Architecture: Round-Based TWAB

TWAB tracking is managed per-round via the `Round` resource, which is created fresh for each lottery period. This design:
- Isolates each draw period's TWAB data
- Automatically resets when a new round starts
- Is immune to duration changes (TWAB is calculated at finalization, not projected)

### State Variables

```cadence
resource Round {
    // Round timing
    access(all) let roundID: UInt64
    access(all) let startTime: UFix64
    access(all) let configuredDuration: UFix64
    access(self) var actualEndTime: UFix64?
    
    // Per-user cumulative TWAB tracking
    access(self) var userAccumulatedTWAB: {UInt64: UFix64}
    access(self) var userLastUpdateTime: {UInt64: UFix64}
    access(self) var userSharesAtLastUpdate: {UInt64: UFix64}
}
```

### Key Functions

#### `recordShareChange(receiverID, oldShares, newShares, atTime)` — Mutating Function

Called on deposit/withdraw to accumulate TWAB up to current time:

```cadence
access(contract) fun recordShareChange(
    receiverID: UInt64,
    oldShares: UFix64,
    newShares: UFix64,
    atTime: UFix64
) {
    // First, accumulate any pending share-seconds for old balance
    self.accumulatePendingTWAB(receiverID: receiverID, upToTime: atTime, withShares: oldShares)
    
    // Update shares snapshot for future accumulation
    self.userSharesAtLastUpdate[receiverID] = newShares
    self.userLastUpdateTime[receiverID] = atTime
}
```

#### `getCurrentTWAB(receiverID, currentShares, atTime)` — View Function

Returns current TWAB for a user (accumulated + pending):

```cadence
access(all) view fun getCurrentTWAB(
    receiverID: UInt64,
    currentShares: UFix64,
    atTime: UFix64
): UFix64 {
    let accumulated = self.userAccumulatedTWAB[receiverID] ?? 0.0
    let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
    let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
    
    // Calculate pending from last update to now
    var pending: UFix64 = 0.0
    if atTime > lastUpdate {
        pending = shares * (atTime - lastUpdate)
    }
    
    return accumulated + pending
}
```

#### `finalizeTWAB(receiverID, currentShares, roundEndTime)` — View Function

Calculates final TWAB at round end (used during draw processing):

```cadence
access(all) view fun finalizeTWAB(
    receiverID: UInt64,
    currentShares: UFix64,
    roundEndTime: UFix64
): UFix64 {
    let accumulated = self.userAccumulatedTWAB[receiverID] ?? 0.0
    let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
    let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
    
    // Calculate remaining from last update to round end
    var pending: UFix64 = 0.0
    if roundEndTime > lastUpdate {
        pending = shares * (roundEndTime - lastUpdate)
    }
    
    return accumulated + pending
}
```

### Why Cumulative (Not Projection-Based)?

The previous implementation used **projections**: on each deposit/withdraw, we calculated
what the user's TWAB *would be* at the round's planned end time.

**Problem**: If an admin changed the round duration mid-round, all stored projections 
became invalid because they were calculated using the old duration.

**Solution**: Store **cumulative** TWAB (actual share-seconds from round start to last update),
then calculate the final value at draw time using the actual round end timestamp. This is:
- **Duration-independent**: No stored values reference the duration
- **Accurate**: Final TWAB uses actual end time, not projected
- **Flexible**: Admins can adjust duration without corrupting TWAB data

---

## Round System

### Purpose

Rounds bound the TWAB accumulation to discrete lottery periods:

- **Round N**: Accumulate TWAB from draw N-1 to draw N
- **Draw N**: Finalize all TWAB values using actual end time, select winner
- **Round N+1**: Fresh Round resource created, TWAB starts at zero

### Round Transitions

When `startDraw()` is called:

1. The actual end time is set on the active round: `activeRound.setActualEndTime(now)`
2. A new Round resource is created for the next period
3. The ended round is moved to `pendingDrawRound` for processing
4. During `processDrawBatch()`, each user's TWAB is finalized with `finalizeTWAB()`

```cadence
// In startDraw():
self.activeRound.setActualEndTime(now)

let newRound <- create Round(
    roundID: endedRoundID + 1,
    startTime: now,
    configuredDuration: roundDuration
)

let endedRound <- self.activeRound <- newRound
self.pendingDrawRound <-! endedRound
```

### Automatic Reset

Unlike epoch-based systems that require lazy resets, the Round-based approach uses 
resource lifecycle for automatic cleanup:

- Each Round is a separate resource with its own TWAB dictionaries
- When a new Round is created, it starts with empty TWAB tracking
- The old Round is destroyed after `completeDraw()` finishes
- No lazy reset logic needed—users start fresh in each Round

### Lazy Initialization for Non-Interactors

Users who never deposit/withdraw during a round still get fair TWAB:

```cadence
// In getCurrentTWAB and finalizeTWAB:
let accumulated = self.userAccumulatedTWAB[receiverID] ?? 0.0
let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares

// If user never interacted, lastUpdate = startTime, shares = currentShares
// So TWAB = currentShares × (endTime - startTime) = full round credit
```

This gives non-interacting users full credit for their shares over the entire round.

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

### User Deposits After Round Start, Never Interacts Again

The `finalizeTWAB()` view function correctly calculates TWAB at draw time:

```cadence
// User has no explicit TWAB data, so defaults are used:
let accumulated = 0.0  // nil → 0.0
let lastUpdate = self.startTime  // nil → round start
let shares = currentShares  // nil → current balance

// Result: currentShares × (roundEndTime - startTime) = full round credit
```

### User from Previous Round Doesn't Interact

Each Round is a fresh resource with empty dictionaries. Users from previous rounds 
automatically get full credit in the new round via lazy initialization:
- Their `userAccumulatedTWAB` is nil → starts at 0
- Their `userLastUpdateTime` is nil → defaults to round start
- Their `userSharesAtLastUpdate` is nil → uses current shares

### Zero Share Balance

If a user has no shares:
```cadence
let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
// If currentShares = 0, then TWAB = 0 × elapsed = 0.0
```

### Admin Changes Duration Mid-Round

This is the key edge case that drove the cumulative design:
- Old projection-based: Stored values become invalid
- New cumulative-based: No impact, final TWAB calculated at draw time

```cadence
// Example: Round starts with 7-day duration, admin changes to 5 days
// User deposited 100 shares at start

// OLD (broken): userProjectedTWAB = 100 × 604800 (7 days in seconds)
// But round ends at 5 days, so projection is wrong!

// NEW (correct): userAccumulatedTWAB = 0, lastUpdate = startTime
// At draw: finalizeTWAB calculates 100 × actualDuration (5 days)
```

---

## Integration with Lottery

### Draw Flow (Batched)

1. **`startDraw()` called:**
   ```cadence
   // Set actual end time on the round being finalized
   self.activeRound.setActualEndTime(now)
   
   // Create new round, swap with active
   let newRound <- create Round(roundID: newRoundID, startTime: now, configuredDuration: duration)
   let endedRound <- self.activeRound <- newRound
   self.pendingDrawRound <-! endedRound
   
   // Create batch processing state
   self.pendingSelectionData <-! create BatchSelectionData(snapshotCount: receiverCount)
   ```

2. **`processDrawBatch(limit)` called repeatedly:**
   ```cadence
   let roundEndTime = pendingRound.getActualEndTime() ?? pendingRound.getConfiguredEndTime()
   let roundStartTime = pendingRound.getStartTime()
   let actualDuration = roundEndTime - roundStartTime
   
   for receiverID in batch {
       let shares = self.savingsDistributor.getUserShares(receiverID: receiverID)
       
       // Finalize TWAB using actual round end time
       let twabStake = pendingRound.finalizeTWAB(
           receiverID: receiverID,
           currentShares: shares,
           roundEndTime: roundEndTime
       )
       
       // Scale bonus by actual duration
       let scaledBonus = bonusWeight * actualDuration
       let totalWeight = twabStake + scaledBonus
       
       selectionData.addEntry(receiverID: receiverID, weight: totalWeight)
   }
   ```

3. **`requestDrawRandomness()` called:**
   ```cadence
   // Batch processing complete, request randomness from Flow
   let randomRequest <- self.randomConsumer.requestRandomness()
   self.pendingDrawReceipt <-! create PrizeDrawReceipt(request: <- randomRequest)
   ```

4. **`completeDraw()` uses selection data:**
   ```cadence
   // Selection data has cumulative weights for binary search
   let selectionData = self.pendingSelectionData!
   let winnerID = selectionData.selectWinner(randomNumber: randomNumber)
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
3. **Using cumulative tracking** instead of projections (immune to duration changes)
4. **Resetting each round** via fresh Round resources
5. **Supporting bonus weights** that are also time-scaled
6. **Snapshotting at commit time** to prevent post-randomness manipulation
7. **Using batched processing** for scalability with large user bases

This creates a lottery system where consistent, long-term participants have proportionally fair odds compared to opportunistic large depositors. The cumulative approach also ensures admin configuration changes (like adjusting draw intervals) don't corrupt existing TWAB data.

