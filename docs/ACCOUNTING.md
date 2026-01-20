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
  - [Projection-Based TWAB](#projection-based-twab)
  - [Round Lifecycle](#round-lifecycle)
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
/// Sum of all user principal deposits (excludes earned interest)
access(all) var totalDeposited: UFix64

/// Amount tracked as being in the yield source
/// Includes: principal + reinvested savings yield
access(all) var totalStaked: UFix64

/// Lottery funds still earning in yield source (not yet withdrawn)
/// Materialized to prize pool at draw time
access(all) var pendingPrizeYield: UFix64

/// Treasury funds still earning in yield source (not yet withdrawn)
/// Materialized and forwarded to recipient (or unclaimed vault) at draw time
access(all) var pendingTreasuryYield: UFix64
```

### SavingsDistributor Variables

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

```cadence
/// Original principal deposited (excludes earned interest)
access(self) let receiverDeposits: {UInt64: UFix64}

/// Total prizes won over all time
access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
```

### Key Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                    ACCOUNTING RELATIONSHIPS                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  allocatedFunds = totalStaked + pendingPrizeYield             │
│                 + pendingTreasuryYield                          │
│                                                                 │
│  allocatedFunds = yieldSource.balance()                         │
│  (must be equal after every sync)                               │
│                                                                 │
│  totalStaked >= totalDeposited                                  │
│  (difference = reinvested savings yield)                        │
│                                                                 │
│  SavingsDistributor.totalAssets = totalStaked                   │
│                                                                 │
│  Σ(userShareValues) = totalAssets                               │
│                                                                 │
│  userBalance = principal + savingsInterest                      │
│              = receiverDeposits[id] + (shareValue - principal)  │
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
    let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES  // +1.0
    let effectiveAssets = self.totalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS  // +1.0
    
    if assets > 0.0 {
        let maxSafeAssets = UFix64.max / effectiveShares
        assert(assets <= maxSafeAssets, message: "Deposit amount too large - would cause overflow")
    }
    
    return (assets * effectiveShares) / effectiveAssets
}
```

**Formula**: `shares = (depositAmount × (totalShares + 1)) / (totalAssets + 1)`

#### Converting Shares to Assets (Value Lookup)

```cadence
access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
    // Virtual offset: (shares * (totalAssets + 1)) / (totalShares + 1)
    let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES  // +1.0
    let effectiveAssets = self.totalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS  // +1.0
    
    if shares > 0.0 {
        let maxSafeShares = UFix64.max / effectiveAssets
        assert(shares <= maxSafeShares, message: "Share amount too large - would cause overflow")
    }
    
    return (shares * effectiveAssets) / effectiveShares
}
```

**Formula**: `value = (userShares × (totalAssets + 1)) / (totalShares + 1)`

#### Share Price

```
sharePrice = (totalAssets + 1) / (totalShares + 1)
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
access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
    // 1. Validate
    pre {
        from.balance > 0.0: "Deposit amount must be positive"
        from.getType() == self.config.assetType: "Invalid vault type"
        self.registeredReceivers[receiverID] == true: "Receiver not registered"
    }
    
    // 2. Process pending yield FIRST (prevents dilution)
    if self.getAvailableYieldRewards() > 0.0 {
        self.processRewards()
    }
    
    // 3. Calculate shares to mint
    let amount = from.balance
    let sharesToMint = self.savingsDistributor.convertToShares(amount)
    
    // 4. Update state
    self.savingsDistributor.deposit(receiverID: receiverID, amount: amount)
    
    // 5. Track principal separately
    let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
    self.receiverDeposits[receiverID] = currentPrincipal + amount
    
    // 6. Update pool totals
    self.totalDeposited = self.totalDeposited + amount
    self.totalStaked = self.totalStaked + amount
    
    // 7. Send to yield source
    self.config.yieldConnector.depositCapacity(from: &from)
    destroy from
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
access(all) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
    // 1. Process pending yield (so user gets their fair share)
    if self.getAvailableYieldRewards() > 0.0 {
        self.processRewards()
    }
    
    // 2. Get user's total balance (principal + interest)
    let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
    assert(totalBalance >= amount, message: "Insufficient balance")
    
    // 3. Withdraw from yield source
    let withdrawn <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
    let actualWithdrawn = withdrawn.balance
    
    // 4. Calculate and burn shares
    let sharesToBurn = (actualWithdrawn * self.totalShares) / self.totalAssets
    self.savingsDistributor.withdraw(receiverID: receiverID, amount: actualWithdrawn)
    
    // 5. Update principal tracking (interest is withdrawn first)
    let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
    let interestEarned = totalBalance > currentPrincipal 
        ? totalBalance - currentPrincipal 
        : 0.0
    let principalWithdrawn = actualWithdrawn > interestEarned 
        ? actualWithdrawn - interestEarned 
        : 0.0
    
    if principalWithdrawn > 0.0 {
        self.receiverDeposits[receiverID] = currentPrincipal - principalWithdrawn
        self.totalDeposited = self.totalDeposited - principalWithdrawn
    }
    
    // 6. Update staked total
    self.totalStaked = self.totalStaked - actualWithdrawn
    
    return <- withdrawn
}
```

### Principal vs Interest Tracking

When a user withdraws, we track whether they're withdrawing interest or principal:

```
User state:
  principal (receiverDeposits): 100
  shareValue: 115 (earned 15 in interest)

Withdraw 20:
  interestEarned = 115 - 100 = 15
  principalWithdrawn = 20 - 15 = 5
  
  New principal = 100 - 5 = 95
  Remaining shareValue = 95
```

This tracking enables analytics and ensures `totalDeposited` accurately reflects principal only.

---

## Yield Distribution

### The syncWithYieldSource Function

The `syncWithYieldSource` function synchronizes internal accounting with the actual yield source balance. It handles both **appreciation** (excess yield) and **depreciation** (deficits).

```cadence
access(contract) fun syncWithYieldSource() {
    let yieldBalance = self.config.yieldConnector.minimumAvailable()
    let allocatedFunds = self.totalStaked + self.pendingPrizeYield + self.pendingTreasuryYield
    
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
    
    // 2. Distribute to savings (O(1) - just update totalAssets)
    if plan.rewardsAmount > 0.0 {
        self.savingsDistributor.accrueYield(amount: plan.rewardsAmount)
        self.totalStaked = self.totalStaked + plan.rewardsAmount
    }
    
    // 3. Track lottery funds (stay in yield source until draw)
    if plan.lotteryAmount > 0.0 {
        self.pendingPrizeYield = self.pendingPrizeYield + plan.lotteryAmount
    }
    
    // 4. Track treasury funds (stay in yield source until draw)
    if plan.treasuryAmount > 0.0 {
        self.pendingTreasuryYield = self.pendingTreasuryYield + plan.treasuryAmount
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
    let lotteryAmount: UFix64   // Funds prize pool
    let treasuryAmount: UFix64  // Protocol fees
}
```

### FixedPercentageStrategy Example

```cadence
let strategy = FixedPercentageStrategy(
    savings: 0.50,   // 50% to savings interest
    lottery: 0.30,   // 30% to lottery prizes
    treasury: 0.20   // 20% to protocol treasury
)

// With 100 FLOW yield:
// savings: 50 FLOW → increases share price (tracked in totalStaked)
// lottery: 30 FLOW → tracked in pendingPrizeYield
// treasury: 20 FLOW → tracked in pendingTreasuryYield
```

### Where Funds Go

| Destination | Storage | When Materialized |
|-------------|---------|-------------------|
| Savings | Stays in yield source, tracked in `totalStaked` | Immediate (share price increases) |
| Lottery | Stays in yield source, tracked in `pendingPrizeYield` | At draw time → prize pool |
| Treasury | Stays in yield source, tracked in `pendingTreasuryYield` | At draw time → recipient or unclaimed vault |

### Draw-Time Materialization

At the start of each lottery draw, pending funds are materialized:

```cadence
// In startDraw():
// 1. Materialize lottery funds
if self.pendingPrizeYield > 0.0 {
    let lotteryVault <- self.config.yieldConnector.withdrawAvailable(
        maxAmount: self.pendingPrizeYield
    )
    self.prizeDistributor.fundPrizePool(vault: <- lotteryVault)
    self.pendingPrizeYield = 0.0
}

// 2. Materialize treasury funds
if self.pendingTreasuryYield > 0.0 {
    let treasuryVault <- self.config.yieldConnector.withdrawAvailable(
        maxAmount: self.pendingTreasuryYield
    )
    self.pendingTreasuryYield = 0.0
    
    if let recipientRef = self.treasuryRecipientCap?.borrow() {
        // Forward to configured recipient
        recipientRef.deposit(from: <- treasuryVault)
    } else {
        // Store in unclaimed vault for admin withdrawal
        self.unclaimedTreasuryVault.deposit(from: <- treasuryVault)
    }
}
```

---

## Deficit Handling

### What is a Deficit?

A **deficit** occurs when the yield source balance is less than `allocatedFunds`. This can happen when:

- The underlying DeFi protocol experiences a loss (slashing, bad debt, etc.)
- External market conditions reduce asset value
- A hack or exploit affects the yield source

```
allocatedFunds = totalStaked + pendingPrizeYield + pendingTreasuryYield

DEFICIT occurs when:
yieldSource.balance() < allocatedFunds
```

### Deficit Distribution

Deficits are distributed proportionally according to the same distribution strategy used for yield:

```cadence
// Example: 50% savings, 30% lottery, 20% treasury strategy
// With a 100 FLOW deficit:
//   - Treasury absorbs: 20 FLOW
//   - Lottery absorbs: 30 FLOW  
//   - Savings absorbs: 50 FLOW
```

### Shortfall Priority (Protect User Principal)

When an allocation can't fully cover its share, the shortfall cascades in this priority order:

```
┌─────────────────────────────────────────────────────────────────┐
│              DEFICIT ABSORPTION PRIORITY ORDER                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. TREASURY (First)                                            │
│     → Protocol absorbs loss first                               │
│     → Capped by pendingTreasuryYield                            │
│     → Shortfall cascades to lottery                             │
│                                                                 │
│  2. LOTTERY (Second)                                            │
│     → Prize pool absorbs its share + treasury shortfall         │
│     → Capped by pendingPrizeYield                             │
│     → Shortfall cascades to savings                             │
│                                                                 │
│  3. SAVINGS (Last)                                              │
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
    
    // 1. Treasury absorbs first (protocol takes loss before users)
    var treasuryShortfall: UFix64 = 0.0
    if plan.treasuryAmount > self.pendingTreasuryYield {
        treasuryShortfall = plan.treasuryAmount - self.pendingTreasuryYield
        self.pendingTreasuryYield = 0.0
    } else {
        self.pendingTreasuryYield = self.pendingTreasuryYield - plan.treasuryAmount
    }
    
    // 2. Lottery absorbs its share + treasury shortfall
    let totalLotteryTarget = plan.lotteryAmount + treasuryShortfall
    var lotteryShortfall: UFix64 = 0.0
    if totalLotteryTarget > self.pendingPrizeYield {
        lotteryShortfall = totalLotteryTarget - self.pendingPrizeYield
        self.pendingPrizeYield = 0.0
    } else {
        self.pendingPrizeYield = self.pendingPrizeYield - totalLotteryTarget
    }
    
    // 3. Savings absorbs remainder (share price decrease)
    let totalSavingsLoss = plan.rewardsAmount + lotteryShortfall
    self.savingsDistributor.decreaseTotalAssets(amount: totalSavingsLoss)
    self.totalStaked = self.totalStaked - totalSavingsLoss
}
```

### Deficit Example

```
Initial State (after yield accumulation):
  totalStaked = 110 (100 deposit + 10 savings yield)
  pendingPrizeYield = 6
  pendingTreasuryYield = 4
  allocatedFunds = 110 + 6 + 4 = 120

Deficit of 20 FLOW occurs (yield source now has 100):
  Strategy: 50% savings, 30% lottery, 20% treasury
  
  Target losses:
    treasury: 20 * 0.20 = 4
    lottery:  20 * 0.30 = 6
    savings:  20 * 0.50 = 10

  Step 1: Treasury absorbs 4 (has 4, exactly covers its share)
    pendingTreasuryYield: 4 → 0
    treasuryShortfall: 0

  Step 2: Lottery absorbs 6 (has 6, exactly covers its share)
    pendingPrizeYield: 6 → 0
    lotteryShortfall: 0

  Step 3: Savings absorbs 10
    totalStaked: 110 → 100
    Share price decreases proportionally

Final State:
  totalStaked = 100
  pendingPrizeYield = 0
  pendingTreasuryYield = 0
  allocatedFunds = 100 (matches yield source balance ✓)
```

### Shortfall Cascade Example

```
State:
  totalStaked = 103
  pendingPrizeYield = 3
  pendingTreasuryYield = 4
  allocatedFunds = 110

Deficit of 20 FLOW (larger than all pending yield):
  Strategy: 30% savings, 30% lottery, 40% treasury

  Target losses:
    treasury: 20 * 0.40 = 8
    lottery:  20 * 0.30 = 6
    savings:  20 * 0.30 = 6

  Step 1: Treasury absorbs (has 4, needs 8)
    absorbed: 4
    treasuryShortfall: 8 - 4 = 4
    pendingTreasuryYield: 4 → 0

  Step 2: Lottery absorbs (has 3, needs 6 + 4 = 10)
    absorbed: 3
    lotteryShortfall: 10 - 3 = 7
    pendingPrizeYield: 3 → 0

  Step 3: Savings absorbs (its 6 + 7 shortfall = 13)
    totalStaked: 103 → 90
    Share price decrease: ~12.6%

Final State:
  totalStaked = 90
  pendingPrizeYield = 0
  pendingTreasuryYield = 0
  allocatedFunds = 90 (matches yield source balance ✓)
```

### Why This Priority Order?

1. **Treasury first**: The protocol should absorb losses before users. Treasury represents protocol revenue that hasn't been claimed yet.

2. **Lottery second**: Prize pool losses affect future winners, not current depositors' principal. It's "house money" from unrealized yield.

3. **Savings last**: User principal is the most important to protect. Only after exhausting treasury and lottery buffers do user deposits take a haircut.

This design philosophy prioritizes user trust and principal protection while allowing the protocol to operate as a buffer against losses.

---

## Invariants

### Critical Invariants (Must Always Hold)

1. **Allocated Funds = Yield Source Balance** (after every sync)
   ```
   totalStaked + pendingPrizeYield + pendingTreasuryYield == yieldSource.balance()
   ```
   This is the most important invariant. It ensures no "ghost" funds exist in the yield source that aren't tracked.

2. **Sum of User Values = Total Assets**
   ```
   Σ(convertToAssets(userShares[id])) == totalAssets
   ```

3. **Total Staked ≥ Total Deposited** (during normal operation)
   ```
   totalStaked >= totalDeposited
   // Difference is reinvested savings yield
   // Note: May be violated during severe deficits
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
   pendingPrizeYield >= 0
   pendingTreasuryYield >= 0
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
  savings: 5 FLOW
  lottery: 4 FLOW
  treasury: 1 FLOW

After processRewards():
  totalShares = 100 (unchanged)
  totalAssets = 105 (100 + 5 savings)
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
  receiverDeposits[A] = 100 (principal)
  User A value = 150 FLOW (50 interest earned)

User A withdraws 75 FLOW:
  sharesToBurn = (75 × 100) / 150 = 50 shares
  interestEarned = 150 - 100 = 50
  principalWithdrawn = 75 - 50 = 25

After:
  totalShares = 50
  totalAssets = 75
  userShares[A] = 50
  receiverDeposits[A] = 75 (100 - 25)
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
access(all) let VIRTUAL_SHARES: UFix64 = 1.0
access(all) let VIRTUAL_ASSETS: UFix64 = 1.0

// Applied in conversions
let effectiveShares = self.totalShares + VIRTUAL_SHARES
let effectiveAssets = self.totalAssets + VIRTUAL_ASSETS
```

This ensures:
- Share price starts near 1:1 even for empty pools
- No special-casing for first deposit
- Donations cannot manipulate share price when `totalShares` is small
- Defense-in-depth for future yield connectors that might be permissionless

### Overflow Protection

```cadence
access(all) view fun convertToShares(_ assets: UFix64): UFix64 {
    let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
    let effectiveAssets = self.totalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS
    
    if assets > 0.0 {
        let maxSafeAssets = UFix64.max / effectiveShares
        assert(assets <= maxSafeAssets, message: "Deposit too large - would overflow")
    }
    return (assets * effectiveShares) / effectiveAssets
}
```

### Empty Pool (First Deposit)

With virtual offset, empty pools are handled uniformly—no special case needed:

```cadence
// When totalShares = 0 and totalAssets = 0:
// effectiveShares = 0 + 1 = 1
// effectiveAssets = 0 + 1 = 1
// shares = (assets * 1) / 1 = assets

// First deposit of 100 FLOW → 100 shares (near 1:1 ratio)
```

### Zero Balance Check

Division by zero is prevented by virtual offset:

```cadence
access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
    // effectiveShares is always >= 1.0, so division is safe
    let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
    let effectiveAssets = self.totalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS
    return (shares * effectiveAssets) / effectiveShares
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

Time-Weighted Average Balance (TWAB) determines prize weight. Users who deposit more, for longer, have higher prize odds. The system uses a **per-round, projection-based** approach with **batched draw processing**.

### Architecture Overview

```
                    Pool
                      │
          ┌──────────┴──────────┐
          │                     │
    SavingsDistributor    activeRound: Round
    (ERC4626 shares only)       │
                                ├── roundID
                                ├── startTime
                                ├── duration
                                ├── endTime
                                ├── userProjectedTWAB: {receiverID: UFix64}
                                └── batchState: BatchCaptureState?
                                      │
                                      ├── receiverSnapshot: [UInt64]
                                      ├── cursor: Int
                                      ├── capturedWeights: {UInt64: UFix64}
                                      ├── totalWeight: UFix64
                                      └── isComplete: Bool
```

Key design decisions:
- **Per-Round Resources**: Each lottery round is a separate `Round` resource
- **SavingsDistributor Decoupling**: TWAB is separate from ERC4626 share accounting
- **Projection-Based**: Store projected end-of-round value, not accumulated value
- **Double-Buffering**: `activeRound` and `pendingDrawRound` allow continuous operation during draws
- **Batched Processing**: O(n) weight capture split across multiple transactions

### Projection-Based TWAB

Instead of accumulating share-seconds over time, we **project** what the TWAB will be at round end.

**On Deposit at round start:**
```
projectedTWAB = shares × roundDuration
// Example: 100 shares × 1 week = 100 entries at round end
```

**On Mid-Round Deposit (t = halfway):**
```
remainingTime = roundDuration / 2
projectedTWAB = shares × remainingTime
// Example: 100 shares × 0.5 week = 50 entries at round end
```

**On Withdrawal:**
```
// Subtract the withdrawn shares' future contribution
adjustment = -withdrawnShares × remainingTime
projectedTWAB = currentProjection + adjustment
```

### Key Formulas

```cadence
// When shares change at time `t`:
remainingTime = endTime - t
shareDelta = newShares - oldShares
projectedTWAB = currentProjection + (shareDelta × remainingTime)

// For users who haven't interacted (lazy fallback):
projectedTWAB = currentShares × roundDuration
```

### Round Lifecycle

1. **Round Creation**: Created with `roundID`, `startTime`, and `duration`
2. **Active Period**: Deposits/withdrawals adjust projections
3. **Round End**: `endTime` passed, but round still "active" until `startDraw()`
4. **Gap Period**: Between round end and `startDraw()` call
5. **Batch Processing**: TWAB weights captured incrementally via `processDrawBatch()`
6. **Randomness Committed**: `requestDrawRandomness()` materializes yield and commits
7. **Destroyed**: After `completeDraw()` distributes prizes

### 4-Phase Draw Process

The draw process is split into 4 phases to avoid O(n) bottlenecks:

```
┌─────────────────────────────────────────────────────────────────┐
│                    4-PHASE DRAW PROCESS                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Phase 1: startDraw() - INSTANT                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. activeRound (ended) → pendingDrawRound               │   │
│  │ 2. Initialize batch state with receiver snapshot        │   │
│  │ 3. Create new activeRound starting NOW                  │   │
│  │ 4. Users immediately unblocked for new round            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Phase 2: processDrawBatch(limit) × N                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Process `limit` receivers from snapshot              │   │
│  │ 2. Capture TWAB + bonus weights                         │   │
│  │ 3. Update cursor and captured weights                   │   │
│  │ 4. Repeat until cursor reaches end                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Phase 3: requestDrawRandomness()                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Materialize pending yield from yield source          │   │
│  │ 2. Create PrizeDrawReceipt with captured weights        │   │
│  │ 3. Request on-chain randomness                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            ↓                                    │
│  Phase 4: completeDraw() (after randomness available)           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. Fulfill randomness, select winners                   │   │
│  │ 2. Auto-compound prizes into winners' deposits          │   │
│  │ 3. Destroy pendingDrawRound                             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Gap Period Handling

The "gap period" is the time between when a round's `endTime` passes and when an admin calls `startDraw()`. This is inevitable since `startDraw()` requires manual triggering.

**Problem**: Users who deposit during the gap shouldn't get credit in the ended round (it's closed), but they also shouldn't lose their contribution.

**Solution**: **Lazy Fallback** - Gap interactors are handled automatically via the projection fallback:

```cadence
// During gap period deposit/withdraw:
1. Finalize user in ended round with pre-transaction shares
2. Proceed with deposit/withdraw into their balance
// (No explicit tracking needed - new round uses lazy fallback)

// In new round, for users who haven't interacted:
getProjectedTWAB(receiverID, currentShares):
    if userProjectedTWAB[receiverID] != nil:
        return userProjectedTWAB[receiverID]  // Explicit value
    else:
        return currentShares × duration        // Lazy fallback

// Gap users automatically get full-round projection via fallback
```

This eliminates the need for explicit gap interactor tracking since:
- Users who interacted in the ended round get their TWAB finalized
- Users in the new round get the lazy fallback (`currentShares × duration`)
- The fallback correctly gives full-round weight to gap depositors

### Batch State Management

The `BatchCaptureState` struct tracks progress across multiple `processDrawBatch()` calls:

```cadence
struct BatchCaptureState {
    receiverSnapshot: [UInt64]     // Frozen list of receiver IDs
    roundDuration: UFix64          // For bonus weight scaling
    cursor: Int                    // Current processing position
    capturedWeights: {UInt64: UFix64}  // Accumulated weights
    totalWeight: UFix64            // Running sum
    isComplete: Bool               // True when cursor reaches end
}
```

Progress can be monitored via `getDrawBatchProgress()`:
```cadence
{
    "cursor": 150,
    "total": 1000,
    "remaining": 850,
    "percentComplete": 15.0,
    "isComplete": false
}
```

### Entry Calculation

**Entries** are human-readable prize weight:

```cadence
entries = projectedTWAB / roundDuration
```

| Scenario | Shares | Deposit Time | Entries |
|----------|--------|--------------|---------|
| Full round | 100 | Round start | 100 |
| Half round | 100 | Halfway | 50 |
| Full round, withdraw half | 100→50 | Start, withdraw at 50% | 75 |

### Benefits of This Design

1. **Instant Round Transition**: `startDraw()` completes immediately, users unblocked
2. **Scalable Draw Processing**: Batch capture works for any number of users
3. **Continuous Operation**: Users can deposit/withdraw during batch processing
4. **Fair Gap Handling**: Lazy fallback gives full credit to gap depositors
5. **Predictable Entries**: Users know their entries instantly after deposit
6. **Clean Separation**: TWAB logic isolated from share accounting
7. **Observable Progress**: Batch progress available via getters

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
| **Principal Protection** | Deficit priority: treasury → lottery → savings |

### Key Design Principles

1. **Shares represent proportional ownership, not absolute balance.** When yield accrues, the pool grows but shares stay constant—everyone's proportional claim on a larger pool automatically increases their value.

2. **All yield stays in the yield source until draw time.** Lottery and treasury portions are tracked via `pendingPrizeYield` and `pendingTreasuryYield`, ensuring `allocatedFunds` always equals the yield source balance.

3. **Deficits are handled with user protection in mind.** The priority order (treasury → lottery → savings) ensures the protocol absorbs losses before users, and lottery pools buffer savings before user principal is affected.

4. **The virtual offset pattern** (adding 1.0 to both shares and assets in conversions) provides defense-in-depth against the ERC4626 inflation attack, ensuring the protocol remains secure even if future yield connectors allow permissionless deposits.

