# Accounting & Shares Model

This document provides an in-depth explanation of the accounting system and ERC4626-style shares model used in PrizeSavings.

## Table of Contents

- [Overview](#overview)
- [Why Shares?](#why-shares)
- [Core Accounting Variables](#core-accounting-variables)
- [The Shares Model](#the-shares-model)
- [Deposit Flow](#deposit-flow)
- [Withdrawal Flow](#withdrawal-flow)
- [Yield Distribution](#yield-distribution)
- [Three-Way Split](#three-way-split)
- [Invariants](#invariants)
- [Examples](#examples)
- [Edge Cases & Protections](#edge-cases--protections)
  - [ERC4626 Donation Attack Protection](#erc4626-donation-attack-protection)

---

## Overview

PrizeSavings uses a **shares-based accounting model** (similar to ERC4626 vault standard) to track user balances and distribute yield. This approach enables:

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
access(all) var pendingLotteryYield: UFix64
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
│  totalStaked ≈ yieldSource.balance()                           │
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
    let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES  // +1.0
    let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS  // +1.0
    
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
    let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES  // +1.0
    let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS  // +1.0
    
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

### The processRewards Function

```cadence
access(contract) fun processRewards() {
    // 1. Calculate available yield
    let yieldBalance = self.config.yieldConnector.minimumAvailable()
    let availableYield = yieldBalance > self.totalStaked 
        ? yieldBalance - self.totalStaked 
        : 0.0
    
    if availableYield == 0.0 {
        return
    }
    
    // 2. Apply distribution strategy (e.g., 50/40/10 split)
    let plan = self.config.distributionStrategy.calculateDistribution(
        totalAmount: availableYield
    )
    
    // 3. Distribute to savings (O(1) - just update totalAssets)
    if plan.savingsAmount > 0.0 {
        self.savingsDistributor.accrueYield(amount: plan.savingsAmount)
        self.totalStaked = self.totalStaked + plan.savingsAmount
    }
    
    // 4. Track lottery funds (stay in yield source earning)
    if plan.lotteryAmount > 0.0 {
        self.pendingLotteryYield = self.pendingLotteryYield + plan.lotteryAmount
    }
    
    // 5. Withdraw treasury funds
    if plan.treasuryAmount > 0.0 {
        let treasuryVault <- self.config.yieldConnector.withdrawAvailable(
            maxAmount: plan.treasuryAmount
        )
        self.treasuryDistributor.deposit(vault: <- treasuryVault)
    }
}
```

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
    let savingsAmount: UFix64   // Goes to shareholders (increases share price)
    let lotteryAmount: UFix64   // Funds lottery prize pool
    let treasuryAmount: UFix64  // Protocol fees
}
```

### FixedPercentageStrategy Example

```cadence
let strategy = FixedPercentageStrategy(
    savings: 0.50,   // 50% to savings interest
    lottery: 0.40,   // 40% to lottery prizes
    treasury: 0.10   // 10% to protocol treasury
)

// With 100 FLOW yield:
// savings: 50 FLOW → increases share price
// lottery: 40 FLOW → funds next draw
// treasury: 10 FLOW → protocol revenue
```

### Where Funds Go

| Destination | Storage | Action |
|-------------|---------|--------|
| Savings | Stays in yield source | Increases `totalAssets` |
| Lottery | `pendingLotteryYield` → withdrawn at draw | Funds prize pool |
| Treasury | `TreasuryDistributor.treasuryVault` | Immediately withdrawn |

---

## Invariants

### Critical Invariants (Must Always Hold)

1. **Sum of User Values = Total Assets**
   ```
   Σ(convertToAssets(userShares[id])) == totalAssets
   ```

2. **Total Staked ≥ Total Deposited**
   ```
   totalStaked >= totalDeposited
   // Difference is reinvested savings yield
   ```

3. **Share/Asset Consistency**
   ```
   convertToAssets(convertToShares(x)) ≈ x  // May differ by rounding
   ```

4. **No Negative Balances**
   ```
   totalShares >= 0
   totalAssets >= 0
   userShares[id] >= 0
   ```

5. **Withdrawal Limit**
   ```
   maxWithdraw(user) <= getUserAssetValue(user)
   ```

### Tested Invariants

From `PrizeSavings_shares_test.cdc`:

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
    let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
    let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS
    
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
    let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
    let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS
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

## Summary

The shares model provides:

| Benefit | How |
|---------|-----|
| **O(1) Interest Distribution** | Increase `totalAssets`, all share values rise |
| **Fair Late-Joiner Handling** | New deposits get fewer shares at higher price |
| **Compound Interest** | Yield stays in pool, increases share value |
| **Gas Efficiency** | Single state update vs. N user updates |
| **Simple Withdrawals** | Burn shares proportional to withdrawal |
| **Auditable State** | `Σ(userValues) == totalAssets` invariant |
| **Donation Attack Protection** | Virtual offset prevents share price manipulation |

Key insight: **Shares represent proportional ownership, not absolute balance.** When yield accrues, the pool grows but shares stay constant—everyone's proportional claim on a larger pool automatically increases their value.

The **virtual offset pattern** (adding 1.0 to both shares and assets in conversions) provides defense-in-depth against the ERC4626 inflation attack, ensuring the protocol remains secure even if future yield connectors allow permissionless deposits.

