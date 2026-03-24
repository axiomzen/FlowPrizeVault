# Time-Weighted Average Balance (TWAB)

This document provides an in-depth explanation of the Time-Weighted Average Balance (TWAB) mechanism used in PrizeLinkedAccounts to ensure fair prize odds.

## Table of Contents

- [Overview](#overview)
- [Why TWAB?](#why-twab)
- [Core Concepts](#core-concepts)
- [Mathematical Foundation](#mathematical-foundation)
- [Implementation Details](#implementation-details)
- [Round System](#round-system)
- [Bonus Weights](#bonus-weights)
- [Examples](#examples)
- [Edge Cases](#edge-cases)
- [Integration with Lottery](#integration-with-lottery)

---

## Overview

TWAB (Time-Weighted Average Balance) is a mechanism that calculates a user's prize odds based on both:

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

TWAB integrates balance over time, producing a **normalized weight** ("average shares"):

```
Round duration: 7 days

User A: 100 tokens for 7 days  → normalized weight = 100.0
User B: 10,000 tokens for 1 hour → normalized weight = 10,000 × (1/168) ≈ 59.5

User A odds: 100.0 / 159.5 ≈ 62.7%
User B odds: 59.5 / 159.5 ≈ 37.3%
```

Despite having 100x the balance, User B's late entry gives them lower odds than User A's long-term holding.

---

## Core Concepts

### Scaled Cumulative Weight

The implementation uses a **scaled** cumulative approach to prevent overflow with large TVL. Instead of raw share-seconds, it accumulates:

```
scaledPending = shares × (elapsed / TWAB_SCALE)
```

Where `TWAB_SCALE = 31,536,000` (1 year in seconds) and `shares` represents the user's proportional ownership in the pool (see [ERC4626 shares model](./ACCOUNTING.md)).

At finalization, the accumulated scaled value is **normalized** back to "average shares":

```
normalizedWeight = totalScaled × (TWAB_SCALE / actualDuration)
```

A user holding 100 shares for the full round gets weight **100** (not 100 x duration). A user holding 100 shares for half the round gets weight **50**.

### Cumulative Tracking

Rather than storing historical balances, we track scaled cumulative weight:

```
userScaledTWAB = Σ(shares × (time_at_each_balance / TWAB_SCALE))
```

This is updated incrementally whenever a user's balance changes.

### Rounds

Each lottery draw period is a **round**. TWAB resets at the start of each round to ensure:
- Previous draws don't affect current odds
- Users start fresh each period
- Memory usage stays bounded

---

## Mathematical Foundation

### Accumulation Formula

For a user with constant shares over a time period:

```
scaledPending = shares × (elapsed / TWAB_SCALE)
```

Where `TWAB_SCALE = 31,536,000.0` (1 year in seconds). The division by `TWAB_SCALE` keeps intermediate values small to prevent overflow.

### With Balance Changes

When a user's share balance changes, we:

1. **Accumulate** the scaled weight up to now
2. **Update** the timestamp
3. **Continue** tracking from the new balance

```
newScaledTWAB = oldScaledTWAB + (oldShares × (timeSinceLastUpdate / TWAB_SCALE))
lastUpdateTime = now
```

### Normalization at Draw Time

At finalization, the total scaled value is normalized to produce "average shares":

```
totalScaled = accumulated + (currentShares × ((roundEndTime - lastUpdateTime) / TWAB_SCALE))
normalizedWeight = totalScaled × (TWAB_SCALE / actualDuration)
```

This yields a value in the same unit as shares. A user holding 100 shares for the full round gets weight 100.

### Lottery Odds

A user's probability of winning:

```
P(win) = userNormalizedWeight / Σ(allUsersNormalizedWeights)
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
    access(all) let roundID: UInt64
    access(all) let startTime: UFix64
    access(all) let TWAB_SCALE: UFix64  // 31_536_000.0 (1 year)
    access(self) var actualEndTime: UFix64?
    access(self) var targetEndTime: UFix64

    access(self) var userScaledTWAB: {UInt64: UFix64}
    access(self) var userLastUpdateTime: {UInt64: UFix64}
    access(self) var userSharesAtLastUpdate: {UInt64: UFix64}
}
```

Note: `targetEndTime` is the minimum time before `startDraw()` can be called. `actualEndTime` is set by `startDraw()` and represents the true end of the round for TWAB calculations.

### Key Functions

#### `recordShareChange(receiverID, oldShares, newShares, atTime)` — Mutating Function

Called on deposit/withdraw to accumulate TWAB up to current time. If the round has ended (`actualEndTime` is set), time is capped so that shares added after round end contribute zero weight:

```cadence
access(contract) fun recordShareChange(
    receiverID: UInt64, oldShares: UFix64, newShares: UFix64, atTime: UFix64
) {
    let effectiveTime = self.actualEndTime != nil && atTime > self.actualEndTime!
        ? self.actualEndTime! : atTime
    self.accumulatePendingTWAB(receiverID: receiverID, upToTime: effectiveTime, withShares: oldShares)
    self.userSharesAtLastUpdate[receiverID] = newShares
    self.userLastUpdateTime[receiverID] = effectiveTime
}
```

#### `getCurrentTWAB(receiverID, currentShares, atTime)` — View Function

Returns current normalized TWAB for a user (accumulated + pending, normalized to "average shares"):

```cadence
access(all) view fun getCurrentTWAB(
    receiverID: UInt64, currentShares: UFix64, atTime: UFix64
): UFix64 {
    let accumulated = self.userScaledTWAB[receiverID] ?? 0.0
    let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
    let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
    var scaledPending: UFix64 = 0.0
    if atTime > lastUpdate {
        scaledPending = shares * ((atTime - lastUpdate) / self.TWAB_SCALE)
    }
    let totalScaled = accumulated + scaledPending
    let elapsedFromStart = atTime - self.startTime
    if elapsedFromStart == 0.0 { return 0.0 }
    let normalizedWeight = totalScaled * (self.TWAB_SCALE / elapsedFromStart)
    if normalizedWeight > shares { return shares }
    return normalizedWeight
}
```

#### `finalizeTWAB(receiverID, currentShares, roundEndTime)` — View Function

Calculates final normalized TWAB at round end (used during draw processing). Same pattern as `getCurrentTWAB` but uses the actual round end time:

```cadence
access(all) view fun finalizeTWAB(
    receiverID: UInt64, currentShares: UFix64, roundEndTime: UFix64
): UFix64 {
    let accumulated = self.userScaledTWAB[receiverID] ?? 0.0
    let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
    let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
    var scaledPending: UFix64 = 0.0
    if roundEndTime > lastUpdate {
        scaledPending = shares * ((roundEndTime - lastUpdate) / self.TWAB_SCALE)
    }
    let totalScaled = accumulated + scaledPending
    let actualDuration = roundEndTime - self.startTime
    if actualDuration == 0.0 { return 0.0 }
    let normalizedWeight = totalScaled * (self.TWAB_SCALE / actualDuration)
    if normalizedWeight > shares { return shares }
    return normalizedWeight
}
```

### Why Cumulative (Not Projection-Based)?

The previous implementation used **projections**: on each deposit/withdraw, we calculated
what the user's TWAB *would be* at the round's planned end time.

**Problem**: If an admin changed the round duration mid-round, all stored projections 
became invalid because they were calculated using the old duration.

**Solution**: Store **scaled cumulative** TWAB (shares x elapsed / TWAB_SCALE from round start to last update),
then normalize at draw time using the actual round end timestamp. This is:
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
2. `BatchSelectionData` is created with a snapshot of the current receiver count
3. Randomness is requested (commit-reveal pattern)
4. The active round stays in place (used during batch processing for TWAB finalization)

During `processDrawBatch()`, each user's TWAB is finalized with `finalizeTWAB()`.

In `completeDraw()`, the active round is destroyed and the pool enters **intermission** (`activeRound == nil`).

A new round is created explicitly by `startNextRound()` (admin, ConfigOps entitlement):

```cadence
// In startDraw():
activeRoundRef.setActualEndTime(now)
self.pendingSelectionData <-! create BatchSelectionData(snapshotCount: receiverCount)
self.pendingDrawReceipt <-! create PrizeDrawReceipt(...)

// In completeDraw():
let usedRound <- self.activeRound <- nil
destroy usedRound  // Pool is now in intermission

// In startNextRound():
self.activeRound <-! create Round(
    roundID: newRoundID,
    startTime: now,
    targetEndTime: now + duration
)
```

### Automatic Reset

Unlike systems that require lazy resets, the Round-based approach uses 
resource lifecycle for automatic cleanup:

- Each Round is a separate resource with its own TWAB dictionaries
- When a new Round is created, it starts with empty TWAB tracking
- The old Round is destroyed after `completeDraw()` finishes
- No lazy reset logic needed—users start fresh in each Round

### Lazy Initialization for Non-Interactors

Users who never deposit/withdraw during a round still get fair TWAB:

```cadence
// In getCurrentTWAB and finalizeTWAB:
let accumulated = self.userScaledTWAB[receiverID] ?? 0.0
let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares

// If user never interacted, lastUpdate = startTime, shares = currentShares
// scaledPending = currentShares × (actualDuration / TWAB_SCALE)
// normalizedWeight = scaledPending × (TWAB_SCALE / actualDuration) = currentShares
// → full round credit
```

This gives non-interacting users full credit for their shares over the entire round.

---

## Bonus Weights

Admins can grant bonus prize weights for promotions or rewards:

```cadence
/// Mapping of receiverID to bonus prize weight.
/// Bonus weight represents equivalent token deposit for the full round duration.
/// A bonus of 5.0 gives the same prize weight as holding 5 tokens for the entire round.
/// Audit trail (reason, timestamp, admin) is preserved in events, not stored here.
access(self) let receiverBonusWeights: {UInt64: UFix64}
```

### How Bonus Weight Works

Since TWAB is **normalized** to "average shares", bonus weight is directly additive:

```cadence
// Bonus weight represents equivalent token deposit for full round.
// Since TWAB is normalized to "average shares", a bonusWeight of 5.0
// is equivalent to holding 5 tokens for the entire draw interval.
let bonusWeight = self.getBonusWeight(receiverID: receiverID)

let totalWeight = twabStake + bonusWeight
```

A bonus of `5.0` gives the user the same prize weight as if they had deposited 5 additional tokens for the entire round duration. No time-scaling is needed because TWAB is already normalized.

### Audit Trail

Bonus weight audit data (reason, timestamp, adminUUID) is **not stored in contract state** but is preserved in **on-chain events**:

- `BonusLotteryWeightSet` - Emitted when a bonus is set/replaced
- `BonusLotteryWeightAdded` - Emitted when weight is added to existing bonus
- `BonusLotteryWeightRemoved` - Emitted when bonus is removed

This keeps contract storage minimal while maintaining full auditability.

### Admin Functions

```cadence
// Set absolute bonus weight
Admin.setBonusLotteryWeight(poolID, receiverID, bonusWeight, reason)

// Add to existing bonus
Admin.addBonusLotteryWeight(poolID, receiverID, additionalWeight, reason)

// Remove all bonus
Admin.removeBonusLotteryWeight(poolID, receiverID)
```

---

## Examples

### Example 1: Single User, Constant Balance

**Setup:**
- User A deposits 1000 tokens at round start
- Round duration: 7 days
- No other users

**Calculation:**
```
shares = 1000 (assuming 1:1 initial ratio)
scaledTWAB = 1000 × (7 days / TWAB_SCALE)
normalizedWeight = scaledTWAB × (TWAB_SCALE / 7 days) = 1000.0

Lottery odds = 100% (only participant)
```

### Example 2: Two Users, Different Entry Times

**Setup:**
- User A deposits 500 tokens at round start
- User B deposits 500 tokens at day 3
- Round duration: 7 days

**Calculation:**
```
User A:
  shares = 500, held for full 7 days
  normalizedWeight = 500.0

User B:
  shares = 500, held for 4 out of 7 days
  normalizedWeight = 500 × (4/7) ≈ 285.7

Total = 785.7

User A odds: 500.0 / 785.7 = 63.6%
User B odds: 285.7 / 785.7 = 36.4%
```

Despite equal balances, User A has better odds due to longer holding time.

### Example 3: Balance Change Mid-Round

**Setup:**
- User A deposits 100 tokens at round start
- After 3 days, User A deposits 400 more tokens (now 500 shares)
- Round duration: 7 days

**Calculation:**
```
Phase 1 (days 0-3):
  shares = 100
  scaledAccumulated = 100 × (3 days / TWAB_SCALE)

Phase 2 (days 3-7):
  shares = 500 (100 original + 400 new)
  scaledPending = 500 × (4 days / TWAB_SCALE)

totalScaled = scaledAccumulated + scaledPending
normalizedWeight = totalScaled × (TWAB_SCALE / 7 days)
               = 100 × (3/7) + 500 × (4/7)
               ≈ 42.9 + 285.7 = 328.6 average shares
```

### Example 4: Whale Attack Prevention

**Setup:**
- User A: 100 tokens for entire 7-day round
- Whale: 10,000 tokens deposited 1 hour before draw

**Calculation:**
```
User A:
  normalizedWeight = 100.0 (full round)

Whale:
  normalizedWeight = 10,000 × (1 hour / 7 days) ≈ 59.5

Total = 159.5

User A odds: 100.0 / 159.5 = 62.7%
Whale odds: 59.5 / 159.5 = 37.3%
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

// scaledPending = currentShares × (actualDuration / TWAB_SCALE)
// normalizedWeight = scaledPending × (TWAB_SCALE / actualDuration) = currentShares
// → full round credit
```

### User from Previous Round Doesn't Interact

Each Round is a fresh resource with empty dictionaries. Users from previous rounds
automatically get full credit in the new round via lazy initialization:
- Their `userScaledTWAB` is nil → starts at 0
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

// NEW (correct): userScaledTWAB = 0, lastUpdate = startTime
// At draw: finalizeTWAB calculates:
//   scaledPending = 100 × (5 days / TWAB_SCALE)
//   normalizedWeight = scaledPending × (TWAB_SCALE / 5 days) = 100
```

---

## Integration with Lottery

### Draw Flow (3 Steps + `startNextRound`)

1. **`startDraw()` called:**
   Sets `actualEndTime` on the active round. Syncs yield. Materializes protocol fee. Requests randomness (commit-reveal). Creates `BatchSelectionData` with snapshot receiver count.
   ```cadence
   // Set actual end time on the active round
   activeRoundRef.setActualEndTime(now)

   // Create batch processing state (snapshot current count to prevent DoS)
   self.pendingSelectionData <-! create BatchSelectionData(
       snapshotCount: self.registeredReceiverList.length
   )

   // Request randomness now - will be fulfilled in completeDraw() after batch processing
   let randomRequest <- self.randomConsumer.requestRandomness()
   self.pendingDrawReceipt <-! create PrizeDrawReceipt(
       prizeAmount: prizeAmount, request: <- randomRequest
   )
   ```

2. **`processDrawBatch(limit)` called repeatedly:**
   For each receiver in snapshot: finalize TWAB (from the active round which still has all TWAB data), add bonus weight, and call `selectionData.addEntry()` to build cumulative weight array.
   ```cadence
   let roundEndTime = activeRoundRef.getActualEndTime()!

   for receiverID in batch {
       let shares = self.shareTracker.getUserShares(receiverID: receiverID)

       // Finalize TWAB using actual round end time
       // Returns NORMALIZED weight (average shares)
       let twabStake = activeRoundRef.finalizeTWAB(
           receiverID: receiverID,
           currentShares: shares,
           roundEndTime: roundEndTime
       )

       // Bonus is directly additive - TWAB is already normalized to "average shares"
       let bonusWeight = self.getBonusWeight(receiverID: receiverID)
       let totalWeight = twabStake + bonusWeight

       selectionData.addEntry(receiverID: receiverID, weight: totalWeight)
   }
   ```

3. **`completeDraw()` called (must be a different block from `startDraw`):**
   Fulfills randomness. Selects winners via binary search over cumulative weights. Distributes prizes. Destroys the active round. Pool enters intermission.
   ```cadence
   // Fulfill randomness request (must be different block from request)
   let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)

   // Select winners using cumulative weight binary search
   let winners = selectionDataRef.selectWinners(count: winnerCount, randomNumber: randomNumber)

   // Distribute prizes, then destroy the active round
   let usedRound <- self.activeRound <- nil
   destroy usedRound  // Pool is now in intermission
   ```

4. **`startNextRound()` called (admin, ConfigOps):**
   Creates a new Round resource, exiting intermission.
   ```cadence
   self.activeRound <-! create Round(
       roundID: newRoundID, startTime: now, targetEndTime: now + duration
   )
   ```

### Why Separate Blocks?

The commit-reveal pattern requires:
1. `startDraw()`: Commit to randomness source (future block), set `actualEndTime`
2. `processDrawBatch()` (repeated): Finalize TWAB weights using the frozen `actualEndTime`
3. `completeDraw()` (different block): Fulfill randomness, select winners

The TWAB snapshot is frozen at `startDraw()` time (via `actualEndTime`), ensuring:
- Users can't manipulate odds after seeing randomness
- The exact weights used for selection are frozen
- Deposits/withdrawals between `startDraw` and `completeDraw` don't affect this draw (time is capped at `actualEndTime` in `recordShareChange`)

---

## Summary

TWAB provides provably fair prize odds by:

1. **Measuring balance x time** instead of just balance
2. **Preventing last-minute manipulation** via time-weighting
3. **Using scaled cumulative tracking** (shares x elapsed / TWAB_SCALE) instead of projections (immune to duration changes and overflow)
4. **Normalizing to "average shares"** at finalization (TWAB_SCALE / actualDuration), making results intuitive
5. **Resetting each round** via fresh Round resources
6. **Supporting bonus weights** that are directly additive (no time-scaling needed since TWAB is already normalized)
7. **Freezing weights at `startDraw()` time** to prevent post-randomness manipulation
8. **Using batched processing** for scalability with large user bases

This creates a lottery system where consistent, long-term participants have proportionally fair odds compared to opportunistic large depositors. The scaled cumulative approach also ensures admin configuration changes (like adjusting draw intervals) don't corrupt existing TWAB data.

