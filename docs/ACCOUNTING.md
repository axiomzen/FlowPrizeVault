# Accounting & Shares Model

This document provides an in-depth explanation of the accounting system and ERC4626-style shares model used in PrizeLinkedAccounts.

## Table of Contents

- [Overview](#overview)
- [Why Shares?](#why-shares)
- [Core Accounting Variables](#core-accounting-variables)
- [The Shares Model](#the-shares-model)
- [Deposit Flow](#deposit-flow)
- [Withdrawal Flow](#withdrawal-flow)
- [Yield Distribution](#yield-distribution)
- [Three-Way Split](#three-way-split)
- [Deficit Handling](#deficit-handling)
- [Invariants](#invariants)
- [Examples](#examples)
- [Edge Cases & Protections](#edge-cases--protections)
  - [ERC4626 Donation Attack Protection](#erc4626-donation-attack-protection)
- [Round-Based TWAB Tracking](#round-based-twab-tracking)
  - [Scaled Cumulative TWAB](#scaled-cumulative-twab)
  - [Round Lifecycle](#round-lifecycle)
  - [3-Phase Draw Process](#3-phase-draw-process)
  - [Gap Period Handling](#gap-period-handling)

---

## Overview

PrizeLinkedAccounts uses a **shares-based accounting model** (similar to ERC4626 vault standard) to track user balances and distribute yield. This approach enables:

1. **O(1) interest distribution** — No loops required to credit each user
2. **Automatic compounding** — Interest accrues to share value, not per-user balances
3. **Fair late-joiner handling** — New depositors don't receive retroactive yield
4. **Gas efficiency** — Single state update distributes to all users

---

## Why Shares?

### The Problem with Per-User Balances

In a naive system tracking individual balances:

```
// Expensive: O(n) loop for every yield distribution
for each user in users:
    user.balance += user.balance * yieldRate
```

With 10,000 users, distributing yield requires 10,000 state updates. This is prohibitively expensive on-chain.

### The Shares Solution

Instead of tracking individual balances, we track:
- **Shares**: User's proportional ownership
- **Total Assets**: What all shares collectively represent

```
// Cheap: O(1) single state update
totalAssets += yieldAmount
// User value automatically increases via share price
```

User balance is computed on-demand:
```
userBalance = (userShares / totalShares) × totalAssets
```

---

## Core Accounting Variables

### Pool-Level Variables

```cadence
/// User portion of yield source balance
/// Includes: deposits + won prizes + accrued rewards yield
/// Updated on: deposit (+), prize (+), rewards yield (+), withdraw (-)
access(all) var userPoolBalance: UFix64

/// Prize funds still earning in yield source (not yet withdrawn)
/// Materialized to prize pool at draw time
access(all) var allocatedPrizeYield: UFix64

/// Protocol funds still earning in yield source (not yet withdrawn)
/// Materialized and forwarded to recipient (or unclaimed vault) at draw time
access(all) var allocatedProtocolFee: UFix64
```

### ShareTracker Variables

```cadence
/// Total shares minted across all users
access(self) var totalShares: UFix64

/// Total assets owned by all shareholders (principal + accrued yield)
access(self) var totalAssets: UFix64

/// Per-user share balances
access(self) let userShares: {UInt64: UFix64}

/// Cumulative yield distributed (for analytics)
access(all) var totalDistributed: UFix64
```

### Per-User Tracking

Per-user balances are derived from `ShareTracker.userShares` via `convertToAssets()`. There is no separate principal tracking — the pool tracks only shares, and the asset value is computed on-demand from the share price.

```cadence
/// Per-user share balances (in ShareTracker)
access(self) let userShares: {UInt64: UFix64}

/// Total prizes won over all time (for analytics)
access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
```

### Key Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                    ACCOUNTING RELATIONSHIPS                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  allocatedFunds = userPoolBalance + allocatedPrizeYield         │
│                 + allocatedProtocolFee                          │
│                                                                 │
│  allocatedFunds = yieldSource.balance()                         │
│  (must be equal after every sync)                               │
│                                                                 │
│  ShareTracker.totalAssets ≈ userPoolBalance                     │
│                                                                 │
│  Σ(userShareValues) ≈ totalAssets                               │
│                                                                 │
│  userBalance = shareTracker.convertToAssets(userShares[id])     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Shares Model

### Core Formulas

The implementation uses a **virtual offset pattern** to prevent the ERC4626 "inflation attack" (donation attack). This adds virtual shares and assets to the conversion formulas.

#### Converting Assets to Shares (Deposit)

```cadence
access(all) view fun convertToShares(_ assets: UFix64): UFix64 {
    // Virtual offset: prevents inflation attacks by ensuring share price 
    // starts near 1:1 and can't be manipulated when totalShares is small
    return assets / self.getSharePrice()
}
```

**Formula**: `shares = assets / sharePrice` where `sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)`

#### Converting Shares to Assets (Value Lookup)

```cadence
access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
    return shares * self.getSharePrice()
}
```

**Formula**: `value = shares × sharePrice` where `sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)`

#### Share Price

```
sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)
```

When yield accrues, `totalAssets` increases while `totalShares` stays constant, so share price rises. The virtual offset ensures the price starts near 1:1 even for an empty pool.

### State Changes

| Operation | totalShares | totalAssets |
|-----------|-------------|-------------|
| Deposit | + shares minted | + deposit amount |
| Withdraw | - shares burned | - withdraw amount |
| Yield Accrual | unchanged | + yield amount |

---

## Deposit Flow

### Step-by-Step Process

```cadence
// Simplified for clarity — see contract for full implementation
access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
    // 1. Validate (positive amount, correct vault type, registered receiver)

    // 2. Sync with yield source FIRST (prevents dilution)
    self.syncWithYieldSource()

    // 3. Mint shares at current share price
    let amount = from.balance
    self.shareTracker.deposit(receiverID: receiverID, amount: amount)

    // 4. Update pool total
    self.userPoolBalance = self.userPoolBalance + amount

    // 5. Record TWAB share change in active round
    self.activeRound.recordShareChange(receiverID, newShares)

    // 6. Send to yield source
    self.config.yieldConnector.deposit(from: <-from)
}
```

### Why Process Yield Before Deposit?

If yield exists but isn't processed, the new depositor would receive shares at a lower price than they should:

```
Before: totalAssets = 100, totalShares = 100, sharePrice = 1.0
Unprocessed yield: 10

Without processing first:
  New deposit 100 → mints 100 shares
  Then process yield: totalAssets = 210, totalShares = 200
  New user gets: (100/200) × 210 = 105 (stole 5 from existing users!)

With processing first:
  Process yield: totalAssets = 110, totalShares = 100, sharePrice = 1.1
  New deposit 100 → mints (100 × 100) / 110 = 90.9 shares
  New user gets: (90.9/190.9) × 210 = 100 (correct!)
```

---

## Withdrawal Flow

### Step-by-Step Process

```cadence
// Simplified for clarity — see contract for full implementation
access(all) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
    // 1. Sync with yield source (so user gets their fair share)
    self.syncWithYieldSource()

    // 2. Validate user has sufficient balance
    let totalBalance = self.shareTracker.getUserAssetValue(receiverID: receiverID)
    assert(totalBalance >= amount, message: "Insufficient balance")

    // 3. Withdraw from yield source
    let withdrawn <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
    let actualWithdrawn = withdrawn.balance

    // 4. Burn shares proportional to withdrawal
    self.shareTracker.withdraw(receiverID: receiverID, amount: actualWithdrawn)

    // 5. Update pool total
    self.userPoolBalance = self.userPoolBalance - actualWithdrawn

    // 6. Record TWAB share change in active round
    self.activeRound.recordShareChange(receiverID, newShares)

    return <- withdrawn
}
```

There is no separate principal tracking. User balances are derived entirely from `ShareTracker.userShares` via `convertToAssets()`.

---

## Yield Distribution

### The syncWithYieldSource Function

The `syncWithYieldSource` function synchronizes internal accounting with the actual yield source balance. It handles both **appreciation** (excess yield) and **depreciation** (deficits).

```cadence
access(contract) fun syncWithYieldSource() {
    let yieldBalance = self.config.yieldConnector.minimumAvailable()
    let allocatedFunds = self.userPoolBalance + self.allocatedPrizeYield + self.allocatedProtocolFee
    
    if yieldBalance > allocatedFunds {
        // EXCESS: Yield source has more than we've tracked
        let excess = yieldBalance - allocatedFunds
        self.applyExcess(amount: excess)
    } else if yieldBalance < allocatedFunds {
        // DEFICIT: Yield source has less than expected (loss)
        let deficit = allocatedFunds - yieldBalance
        self.applyDeficit(amount: deficit)
    }
    // If equal: Nothing to do
}
```

### The applyExcess Function

When excess yield is detected, it's distributed according to the pool's strategy:

```cadence
access(self) fun applyExcess(amount: UFix64) {
    // 1. Apply distribution strategy (e.g., 50/30/20 split)
    let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: amount)
    
    // 2. Distribute to rewards (O(1) - just update totalAssets)
    if plan.rewardsAmount > 0.0 {
        self.shareTracker.accrueYield(amount: plan.rewardsAmount)
        self.userPoolBalance = self.userPoolBalance + plan.rewardsAmount
    }
    
    // 3. Track prize funds (stay in yield source until draw)
    if plan.prizeAmount > 0.0 {
        self.allocatedPrizeYield = self.allocatedPrizeYield + plan.prizeAmount
    }
    
    // 4. Track protocol fee (stay in yield source until draw)
    if plan.protocolFeeAmount > 0.0 {
        self.allocatedProtocolFee = self.allocatedProtocolFee + plan.protocolFeeAmount
    }
}
```

**Key Design: All yield stays in the yield source until draw time.** This ensures:
- `allocatedFunds` always equals the yield source balance after sync
- No accounting gaps from partially-forwarded funds
- Clean round boundaries for prize distribution

### accrueYield - The O(1) Magic

```cadence
access(contract) fun accrueYield(amount: UFix64) {
    if amount == 0.0 || self.totalShares == 0.0 {
        return
    }
    
    // Single state update - all users automatically benefit
    self.totalAssets = self.totalAssets + amount
    self.totalDistributed = self.totalDistributed + amount
}
```

**Before accrual:**
```
totalAssets = 1000, totalShares = 1000
sharePrice = 1.0
User A (500 shares) = 500 tokens
User B (500 shares) = 500 tokens
```

**After accruing 100 yield:**
```
totalAssets = 1100, totalShares = 1000
sharePrice = 1.1
User A (500 shares) = 550 tokens (+50)
User B (500 shares) = 550 tokens (+50)
```

No loops. No per-user updates. Just one addition.

---

## Three-Way Split

### Distribution Strategy

Yield is split between three destinations:

```cadence
struct DistributionPlan {
    let rewardsAmount: UFix64   // Goes to shareholders (increases share price)
    let prizeAmount: UFix64   // Funds prize pool
    let protocolFeeAmount: UFix64  // Protocol fees
}
```

### FixedPercentageStrategy Example

```cadence
let strategy = FixedPercentageStrategy(
    rewards: 0.50,   // 50% to rewards interest
    prize: 0.30,   // 30% to prizes
    protocolFee: 0.20   // 20% to protocol fee
)

// With 100 FLOW yield:
// rewards: 50 FLOW → increases share price (tracked in userPoolBalance)
// prize: 30 FLOW → tracked in allocatedPrizeYield
// protocolFee: 20 FLOW → tracked in allocatedProtocolFee
```

### Where Funds Go

| Destination | Storage | When Materialized |
|-------------|---------|-------------------|
| Rewards | Stays in yield source, tracked in `userPoolBalance` | Immediate (share price increases) |
| Prize | Stays in yield source, tracked in `allocatedPrizeYield` | At draw time → prize pool |
| Protocol Fee | Stays in yield source, tracked in `allocatedProtocolFee` | At draw time → recipient or unclaimed vault |

### Draw-Time Materialization

During the draw process, pending funds are handled differently depending on their type:

**Protocol fee** is materialized (withdrawn from yield source) in `startDraw()`:

```cadence
// In startDraw():
if self.allocatedProtocolFee > 0.0 {
    let protocolVault <- self.config.yieldConnector.withdrawAvailable(
        maxAmount: self.allocatedProtocolFee
    )
    self.allocatedProtocolFee = self.allocatedProtocolFee - protocolVault.balance

    // Forward to recipient or store in unclaimed vault
    ...
}
```

**Prize funds** stay in the yield source and are reallocated via accounting in `completeDraw()` -- no token movement, no slippage:

```cadence
// In completeDraw(), for each winner:
self.allocatedPrizeYield = self.allocatedPrizeYield - prizeAmount
self.shareTracker.deposit(receiverID: winnerID, amount: prizeAmount)
self.userPoolBalance = self.userPoolBalance + prizeAmount
// Funds remain in yield source, continuing to earn
```

---

## Deficit Handling

### What is a Deficit?

A **deficit** occurs when the yield source balance is less than `allocatedFunds`. This can happen when:

- The underlying DeFi protocol experiences a loss (slashing, bad debt, etc.)
- External market conditions reduce asset value
- A hack or exploit affects the yield source

```
allocatedFunds = userPoolBalance + allocatedPrizeYield + allocatedProtocolFee

DEFICIT occurs when:
yieldSource.balance() < allocatedFunds
```

### Deficit Distribution

Deficits are distributed proportionally according to the same distribution strategy used for yield:

```cadence
// Example: 50% rewards, 30% prize, 20% protocol strategy
// With a 100 FLOW deficit:
//   - Protocol absorbs: 20 FLOW
//   - Prize absorbs: 30 FLOW  
//   - Rewards absorbs: 50 FLOW
```

### Shortfall Priority (Protect User Principal)

When an allocation can't fully cover its share, the shortfall cascades in this priority order:

```
┌─────────────────────────────────────────────────────────────────┐
│              DEFICIT ABSORPTION PRIORITY ORDER                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. PROTOCOL FEE (First)                                            │
│     → Protocol fee absorbs loss first                               │
│     → Capped by allocatedProtocolFee                            │
│     → Shortfall cascades to prize                             │
│                                                                 │
│  2. PRIZE (Second)                                            │
│     → Prize pool absorbs its share + protocol fee shortfall         │
│     → Capped by allocatedPrizeYield                             │
│     → Shortfall cascades to rewards                             │
│                                                                 │
│  3. REWARDS (Last)                                              │
│     → User principal is last resort                             │
│     → Absorbs its share + all shortfalls from above             │
│     → Decreases share price for all depositors                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### The applyDeficit Function

```cadence
access(self) fun applyDeficit(amount: UFix64) {
    // Calculate target losses per strategy
    let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: amount)
    
    // 1. Protocol absorbs first (protocol takes loss before users)
    var protocolShortfall: UFix64 = 0.0
    if plan.protocolFeeAmount > self.allocatedProtocolFee {
        protocolShortfall = plan.protocolFeeAmount - self.allocatedProtocolFee
        self.allocatedProtocolFee = 0.0
    } else {
        self.allocatedProtocolFee = self.allocatedProtocolFee - plan.protocolFeeAmount
    }
    
    // 2. Prize absorbs its share + protocol shortfall
    let totalPrizeTarget = plan.prizeAmount + protocolShortfall
    var prizeShortfall: UFix64 = 0.0
    if totalPrizeTarget > self.allocatedPrizeYield {
        prizeShortfall = totalPrizeTarget - self.allocatedPrizeYield
        self.allocatedPrizeYield = 0.0
    } else {
        self.allocatedPrizeYield = self.allocatedPrizeYield - totalPrizeTarget
    }
    
    // 3. Rewards absorbs remainder (share price decrease)
    let totalRewardsLoss = plan.rewardsAmount + prizeShortfall
    self.shareTracker.decreaseTotalAssets(amount: totalRewardsLoss)
    self.userPoolBalance = self.userPoolBalance - totalRewardsLoss
}
```

### Deficit Example

```
Initial State (after yield accumulation):
  userPoolBalance = 110 (100 deposit + 10 rewards yield)
  allocatedPrizeYield = 6
  allocatedProtocolFee = 4
  allocatedFunds = 110 + 6 + 4 = 120

Deficit of 20 FLOW occurs (yield source now has 100):
  Strategy: 50% rewards, 30% prize, 20% protocol
  
  Target losses:
    protocolFee: 20 * 0.20 = 4
    prize:  20 * 0.30 = 6
    rewards:  20 * 0.50 = 10

  Step 1: Protocol absorbs 4 (has 4, exactly covers its share)
    allocatedProtocolFee: 4 → 0
    protocolShortfall: 0

  Step 2: Prize absorbs 6 (has 6, exactly covers its share)
    allocatedPrizeYield: 6 → 0
    prizeShortfall: 0

  Step 3: Rewards absorbs 10
    userPoolBalance: 110 → 100
    Share price decreases proportionally

Final State:
  userPoolBalance = 100
  allocatedPrizeYield = 0
  allocatedProtocolFee = 0
  allocatedFunds = 100 (matches yield source balance ✓)
```

### Shortfall Cascade Example

```
State:
  userPoolBalance = 103
  allocatedPrizeYield = 3
  allocatedProtocolFee = 4
  allocatedFunds = 110

Deficit of 20 FLOW (larger than all pending yield):
  Strategy: 30% rewards, 30% prize, 40% protocol

  Target losses:
    protocolFee: 20 * 0.40 = 8
    prize:  20 * 0.30 = 6
    rewards:  20 * 0.30 = 6

  Step 1: Protocol absorbs (has 4, needs 8)
    absorbed: 4
    protocolShortfall: 8 - 4 = 4
    allocatedProtocolFee: 4 → 0

  Step 2: Prize absorbs (has 3, needs 6 + 4 = 10)
    absorbed: 3
    prizeShortfall: 10 - 3 = 7
    allocatedPrizeYield: 3 → 0

  Step 3: Rewards absorbs (its 6 + 7 shortfall = 13)
    userPoolBalance: 103 → 90
    Share price decrease: ~12.6%

Final State:
  userPoolBalance = 90
  allocatedPrizeYield = 0
  allocatedProtocolFee = 0
  allocatedFunds = 90 (matches yield source balance ✓)
```

### Why This Priority Order?

1. **Protocol first**: The protocol should absorb losses before users. Protocol represents protocol revenue that hasn't been claimed yet.

2. **Lottery second**: Prize pool losses affect future winners, not current depositors' principal. It's "house money" from unrealized yield.

3. **Savings last**: User principal is the most important to protect. Only after exhausting protocol and lottery buffers do user deposits take a haircut.

This design philosophy prioritizes user trust and principal protection while allowing the protocol to operate as a buffer against losses.

---

## Invariants

### Critical Invariants (Must Always Hold)

1. **Allocated Funds = Yield Source Balance** (after every sync)
   ```
   userPoolBalance + allocatedPrizeYield + allocatedProtocolFee == yieldSource.balance()
   ```
   This is the most important invariant. It ensures no "ghost" funds exist in the yield source that aren't tracked.

2. **Sum of User Values = Total Assets**
   ```
   Σ(convertToAssets(userShares[id])) == totalAssets
   ```

3. **User Pool Balance Tracks Share Value**
   ```
   userPoolBalance ≈ ShareTracker.totalAssets
   // Both track user funds; small dust differences possible from virtual offset
   ```

4. **Share/Asset Consistency**
   ```
   convertToAssets(convertToShares(x)) ≈ x  // May differ by rounding
   ```

5. **No Negative Balances**
   ```
   totalShares >= 0
   totalAssets >= 0
   userShares[id] >= 0
   allocatedPrizeYield >= 0
   allocatedProtocolFee >= 0
   ```

6. **Withdrawal Limit**
   ```
   maxWithdraw(user) <= getUserAssetValue(user)
   ```

### Tested Invariants

From `PrizeLinkedAccounts_shares_test.cdc`:

```cadence
access(all) fun testInvariantTotalAssets() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.deposit("userB", 150.0)
    model.distributeInterest(25.0)
    
    // Sum of user values should equal totalAssets
    let sumValues = model.getUserValue("userA") + model.getUserValue("userB")
    assertClose(sumValues, model.totalAssets, 0.01, "Sum of values == totalAssets")
}
```

---

## Examples

### Example 1: First Deposit (1:1 Ratio)

```
Initial state:
  totalShares = 0
  totalAssets = 0

User A deposits 100 FLOW:
  shares = 100 (1:1 for first deposit)
  
After:
  totalShares = 100
  totalAssets = 100
  userShares[A] = 100
  sharePrice = 1.0
  User A value = 100 FLOW
```

### Example 2: Yield Accrual

```
State:
  totalShares = 100
  totalAssets = 100
  userShares[A] = 100

Yield source generates 10 FLOW, split 50/40/10:
  rewards: 5 FLOW
  prize: 4 FLOW
  protocolFee: 1 FLOW

After processRewards():
  totalShares = 100 (unchanged)
  totalAssets = 105 (100 + 5 rewards)
  sharePrice = 1.05
  User A value = 105 FLOW
```

### Example 3: Second Depositor After Yield

```
State:
  totalShares = 100
  totalAssets = 110 (after yield)
  sharePrice = 1.1
  User A value = 110 FLOW

User B deposits 110 FLOW:
  shares = (110 × 100) / 110 = 100 shares

After:
  totalShares = 200
  totalAssets = 220
  sharePrice = 1.1 (unchanged)
  User A value = (100/200) × 220 = 110 FLOW
  User B value = (100/200) × 220 = 110 FLOW
```

User B paid 110 FLOW and got 100 shares worth 110 FLOW. They didn't steal User A's interest.

### Example 4: Partial Withdrawal

```
State:
  totalShares = 100
  totalAssets = 150
  userShares[A] = 100
  sharePrice = 1.5
  User A value = 150 FLOW

User A withdraws 75 FLOW:
  sharesToBurn = 75 / 1.5 = 50 shares

After:
  totalShares = 50
  totalAssets = 75
  userShares[A] = 50
  User A value = 75 FLOW
```

### Example 5: Full Withdrawal

```
State:
  totalShares = 200 (A: 100, B: 100)
  totalAssets = 220
  User A value = 110 FLOW
  User B value = 110 FLOW

User A withdraws all (110 FLOW):
  sharesToBurn = 100

After:
  totalShares = 100
  totalAssets = 110
  userShares[A] = 0
  User B value = 110 FLOW (unchanged!)
```

User A's withdrawal doesn't affect User B's value.

---

## Edge Cases & Protections

### ERC4626 Donation Attack Protection

The **inflation attack** (also known as the "donation attack") is a vulnerability in naive ERC4626 implementations where a malicious first depositor can:

1. Deposit a small amount (e.g., 1 wei) to get 1 share
2. "Donate" a large amount directly to the vault (increasing `totalAssets`)
3. When the next user deposits, they receive 0 shares due to rounding
4. The attacker can then withdraw all funds

**Protection via Virtual Offset:**

The implementation uses virtual shares and assets that create "dead" ownership:

```cadence
// Constants defined at contract level
access(all) let VIRTUAL_SHARES: UFix64 = 0.0001
access(all) let VIRTUAL_ASSETS: UFix64 = 0.0001

// Applied in share price calculation
let effectiveShares = self.totalShares + VIRTUAL_SHARES
let effectiveAssets = self.totalAssets + VIRTUAL_ASSETS
let sharePrice = effectiveAssets / effectiveShares
```

This ensures:
- Share price starts near 1:1 even for empty pools
- No special-casing for first deposit
- Donations cannot manipulate share price when `totalShares` is small
- Defense-in-depth for future yield connectors that might be permissionless

### Overflow Protection

The pool enforces a `SAFE_MAX_TVL` ceiling (~147.5 billion) and validates deposit amounts against it. The `getSharePrice()` computation uses virtual offsets that ensure division by zero is impossible, and the small virtual offset (0.0001) minimizes dilution (~0.0001%) while providing security.

### Empty Pool (First Deposit)

With virtual offset, empty pools are handled uniformly—no special case needed:

```cadence
// When totalShares = 0 and totalAssets = 0:
// effectiveShares = 0 + 0.0001 = 0.0001
// effectiveAssets = 0 + 0.0001 = 0.0001
// sharePrice = 0.0001 / 0.0001 = 1.0
// shares = assets / 1.0 = assets

// First deposit of 100 FLOW → 100 shares (near 1:1 ratio)
```

### Zero Balance Check

Division by zero is prevented by virtual offset:

```cadence
access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
    // getSharePrice() uses effectiveShares (always >= 0.0001), so division is safe
    return shares * self.getSharePrice()
}
```

### Yield Source Liquidity

If yield source can't fulfill a withdrawal:

```cadence
let yieldAvailable = self.config.yieldConnector.minimumAvailable()

if yieldAvailable < amount {
    // Track failure, potentially trigger emergency mode
    self.consecutiveWithdrawFailures = self.consecutiveWithdrawFailures + 1
    emit WithdrawalFailure(...)
    return <- emptyVault
}
```

### Rounding

Share calculations may produce small rounding errors. The protocol handles this by:

1. **Accepting small imprecision** — `assertClose()` tests use tolerance
2. **Always processing yield first** — Prevents compounding rounding errors
3. **Conservative math** — Round in favor of the protocol when ambiguous

---

## Round-Based TWAB Tracking

Time-Weighted Average Balance (TWAB) determines prize weight. Users who deposit more, for longer, have higher prize odds. The system uses a **per-round, scaled cumulative** approach with **batched draw processing**. See `TWAB.md` for detailed mechanics.

### Architecture Overview

```
                    Pool
                      │
          ┌──────────┴──────────┐
          │                     │
    ShareTracker    activeRound: Round
    (ERC4626 shares only)       │
                                ├── roundID
                                ├── startTime
                                ├── targetEndTime
                                ├── actualEndTime (set by startDraw)
                                ├── TWAB_SCALE = 31_536_000.0
                                ├── userScaledTWAB: {receiverID: UFix64}
                                ├── userLastUpdateTime: {receiverID: UFix64}
                                └── userSharesAtLastUpdate: {receiverID: UFix64}

                    pendingSelectionData: BatchSelectionData?
                                      │
                                      ├── receiverIDs: [UInt64]
                                      ├── cumulativeWeights: [UFix64]
                                      ├── totalWeight: UFix64
                                      ├── cursor: Int
                                      └── snapshotReceiverCount: Int
```

Key design decisions:
- **Per-Round Resources**: Each prize round is a separate `Round` resource
- **ShareTracker Decoupling**: TWAB is separate from ERC4626 share accounting
- **Scaled Cumulative**: Accumulate `shares * (elapsed / TWAB_SCALE)` for overflow protection, normalize at finalization
- **Batched Processing**: O(n) weight capture split across multiple transactions
- **Parallel Arrays**: `BatchSelectionData` uses parallel `receiverIDs`/`cumulativeWeights` arrays for O(log n) binary search winner selection

### Scaled Cumulative TWAB

Instead of accumulating raw share-seconds (which overflow with large TVL), the system uses a fixed `TWAB_SCALE` (1 year = 31,536,000 seconds) to keep values small during accumulation, then normalizes by actual round duration at finalization.

**On each share change (deposit/withdraw):**
```
// Accumulate pending weight for old balance
elapsed = now - lastUpdateTime
scaledPending = oldShares × (elapsed / TWAB_SCALE)
userScaledTWAB += scaledPending

// Snapshot new state
userSharesAtLastUpdate = newShares
userLastUpdateTime = now
```

**At finalization (during processDrawBatch):**
```
// Accumulate any remaining pending weight
elapsed = actualEndTime - lastUpdateTime
scaledPending = shares × (elapsed / TWAB_SCALE)
totalScaled = userScaledTWAB + scaledPending

// Normalize to "average shares" using actual round duration
normalizedWeight = totalScaled × (TWAB_SCALE / actualDuration)

// Safety cap: weight cannot exceed current shares
if normalizedWeight > shares:
    normalizedWeight = shares
```

The result is "average shares" — a user holding 100 shares for the full round gets weight 100, a user depositing 100 shares at the halfway point gets weight ~50.

### Key Formulas

```
// Accumulation (on share change at time t):
scaledPending = shares × (elapsed / TWAB_SCALE)
userScaledTWAB = accumulated + scaledPending

// Finalization (during processDrawBatch):
normalizedWeight = totalScaled × (TWAB_SCALE / actualDuration)
normalizedWeight = min(normalizedWeight, shares)  // safety cap
```

### Round Lifecycle

1. **Round Creation**: Created with `roundID`, `startTime`, and `targetEndTime`
2. **Active Period**: Deposits/withdrawals accumulate scaled TWAB
3. **Target End Reached**: `targetEndTime` passed, but round still "active" until `startDraw()`
4. **Gap Period**: Between `targetEndTime` and `startDraw()` call — weight continues accumulating
5. **startDraw()**: Sets `actualEndTime`, syncs yield, materializes protocol fee, requests randomness, creates `BatchSelectionData`
6. **Batch Processing**: TWAB weights finalized incrementally via `processDrawBatch()`
7. **completeDraw()**: Fulfills randomness, selects winners, distributes prizes, destroys round
8. **Intermission**: Pool has no active round until `startNextRound()` is called

### 3-Phase Draw Process

The draw process is split into 3 phases to avoid O(n) bottlenecks:

```
┌─────────────────────────────────────────────────────────────────┐
│                    3-PHASE DRAW PROCESS                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase 1: startDraw()                                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Set actualEndTime on active round                    │   │
│  │ 2. Sync with yield source                               │   │
│  │ 3. Materialize protocol fee from yield source           │   │
│  │ 4. Create BatchSelectionData with receiver snapshot     │   │
│  │ 5. Request on-chain randomness (PrizeDrawReceipt)       │   │
│  │ 6. Pool enters draw-in-progress state                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Phase 2: processDrawBatch(limit) × N                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Finalize TWAB for each receiver in batch             │   │
│  │ 2. Add bonus weights (scaled by round duration)         │   │
│  │ 3. Build cumulative weight array in BatchSelectionData  │   │
│  │ 4. Advance cursor, repeat until complete                │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Phase 3: completeDraw() (must be different block)              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Fulfill randomness from previous block               │   │
│  │ 2. Select winners via weighted random (binary search)   │   │
│  │ 3. Materialize prize yield, distribute to winners       │   │
│  │ 4. Auto-compound prizes into winners' deposits          │   │
│  │ 5. Destroy active round, enter intermission             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Then: startNextRound() to begin next round                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Gap Period Handling

The "gap period" is the time between when a round's `targetEndTime` passes and when an admin calls `startDraw()`. This is inevitable since `startDraw()` requires manual triggering.

**Problem**: Users who deposit during the gap shouldn't get unfair extra credit, but their existing balance should continue accumulating weight normally.

**Solution**: Weight accumulation continues through the gap period. When `startDraw()` is called, it sets `actualEndTime` to the current timestamp. The TWAB calculation uses `actualEndTime` (not `targetEndTime`), so all time from round start through the gap is included in the actual duration. This means:

- Users with shares before the gap get proportional credit for the extra time
- Users who deposit during the gap get credit from their deposit time to `actualEndTime`
- The normalization by `actualDuration` ensures the result is still "average shares"

### Batch Selection Data

The `BatchSelectionData` resource tracks progress across multiple `processDrawBatch()` calls and provides efficient winner selection:

```cadence
resource BatchSelectionData {
    receiverIDs: [UInt64]          // Receivers with weight > 0
    cumulativeWeights: [UFix64]    // Parallel array for binary search
    totalWeight: UFix64            // Sum of all weights (cached)
    cursor: Int                    // Current processing position
    snapshotReceiverCount: Int     // Receiver count at startDraw time
}

// Batch is complete when cursor >= snapshotReceiverCount
```

Winner selection uses the cumulative weight array for O(log n) binary search — a random number in `[0, totalWeight)` maps to the receiver whose cumulative weight range contains it.

### Normalized Weight (Entries)

The normalized weight represents "average shares" and directly serves as prize weight:

| Scenario | Shares | Deposit Time | Normalized Weight |
|----------|--------|--------------|-------------------|
| Full round | 100 | Round start | 100 |
| Half round | 100 | Halfway | ~50 |
| Full round, withdraw half | 100→50 | Start, withdraw at 50% | ~75 |

### Benefits of This Design

1. **Overflow Protection**: Fixed `TWAB_SCALE` keeps intermediate values small regardless of TVL or round duration
2. **Scalable Draw Processing**: Batch capture works for any number of users
3. **Efficient Winner Selection**: Cumulative weight arrays enable O(log n) binary search
4. **Fair Gap Handling**: Actual duration normalization gives proportional credit
5. **Clean Separation**: TWAB logic isolated from share accounting
6. **Observable Progress**: Batch progress available via getters

---

## Summary

The shares model provides:

| Benefit | How |
|---------|-----|
| **O(1) Interest Distribution** | Increase `totalAssets`, all share values rise |
| **Fair Late-Joiner Handling** | New deposits get fewer shares at higher price |
| **Compound Interest** | Yield stays in pool, increases share value |
| **Gas Efficiency** | Single state update vs. N user updates |
| **Simple Withdrawals** | Burn shares proportional to withdrawal |
| **Auditable State** | `allocatedFunds == yieldSource.balance()` invariant |
| **Donation Attack Protection** | Virtual offset prevents share price manipulation |
| **Principal Protection** | Deficit priority: protocol fee → prize → rewards |

### Key Design Principles

1. **Shares represent proportional ownership, not absolute balance.** When yield accrues, the pool grows but shares stay constant—everyone's proportional claim on a larger pool automatically increases their value.

2. **All yield stays in the yield source until draw time.** Prize and protocol fee portions are tracked via `allocatedPrizeYield` and `allocatedProtocolFee`, ensuring `allocatedFunds` always equals the yield source balance.

3. **Deficits are handled with user protection in mind.** The priority order (protocol fee → prize → rewards) ensures the protocol absorbs losses before users, and prize pools buffer savings before user principal is affected.

4. **The virtual offset pattern** (adding 0.0001 to both shares and assets in the share price calculation) provides defense-in-depth against the ERC4626 inflation attack, ensuring the protocol remains secure even if future yield connectors allow permissionless deposits.

