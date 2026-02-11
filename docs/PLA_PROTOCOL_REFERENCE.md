# PrizeLinkedAccounts — Protocol Reference

Complete reference for the PrizeLinkedAccounts contract: what it is, how it works, and how every internal mechanism operates. Written for anyone — developers, auditors, partners — who needs to understand the protocol without reading the source code.

**Contract**: `PrizeLinkedAccounts` on Flow Blockchain (Cadence)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Shares Model (ERC4626)](#3-shares-model-erc4626)
4. [Yield Distribution](#4-yield-distribution)
5. [TWAB (Time-Weighted Average Balance)](#5-twab-time-weighted-average-balance)
6. [Rounds & the Draw Cycle](#6-rounds--the-draw-cycle)
7. [Winner Selection & Randomness](#7-winner-selection--randomness)
8. [Prize Distribution](#8-prize-distribution)
9. [Deficit Handling](#9-deficit-handling)
10. [Emergency System](#10-emergency-system)
11. [Registration & Unregistration](#11-registration--unregistration)
12. [Slippage Protection](#12-slippage-protection)
13. [Sponsor Positions](#13-sponsor-positions)
14. [NFT Prizes](#14-nft-prizes)
15. [Direct Pool Funding](#15-direct-pool-funding)
16. [Protocol Fees](#16-protocol-fees)
17. [Key Invariants](#17-key-invariants)
18. [Entitlements & Access Control](#18-entitlements--access-control)
19. [User Lifecycle Summary](#19-user-lifecycle-summary)
20. [Query Reference](#20-query-reference)
21. [Events Reference](#21-events-reference)
22. [Deployment](#22-deployment)

---

## 1. Overview

PrizeLinkedAccounts is a **no-loss lottery / prize-linked savings** protocol. Users deposit tokens (e.g., pyUSD) into a pool. The pooled tokens are sent to a DeFi yield source where they earn interest. That yield is split three ways:

```
Total Yield
  ├── Rewards (savings)  → Increases everyone's balance automatically
  ├── Prize Pool         → Funds the periodic lottery draw
  └── Protocol Fee       → Revenue for the protocol operator
```

**No one loses their deposit.** The lottery is funded entirely by yield. Users get guaranteed savings interest plus chances to win prizes — the longer they hold and the more they deposit, the better their odds.

### How It Works (30-Second Summary)

1. Users deposit tokens into a pool
2. Tokens earn yield in an external yield source (FlowYieldVaults)
3. Yield is split: part grows everyone's balance, part goes to a prize pool
4. Every round (e.g., 7 days), a draw selects winners weighted by time-held balance (TWAB)
5. Winners' prizes are auto-compounded back into their deposit
6. Users can withdraw anytime — principal plus earned rewards

---

## 2. Architecture

```
PrizeLinkedAccounts (Contract)
├── Admin                         # Privileged operations
├── Pool                          # Core logic per pool
│   ├── ShareTracker              # ERC4626-style share accounting
│   ├── PrizeDistributor          # Prize pool, NFT prizes, pending claims
│   ├── Round (active)            # Current round's TWAB tracking
│   ├── Round (pending draw)      # Previous round being drawn
│   ├── BatchSelectionData        # Winner selection state during draws
│   └── PoolConfig                # Yield connector, strategy, settings
├── PoolPositionCollection        # User resource (prize-eligible)
└── SponsorPositionCollection     # Sponsor resource (prize-ineligible)
```

### Key Design Decisions

- **Shares, not balances**: O(1) yield distribution via share price changes
- **Cumulative TWAB**: Duration-independent, immune to mid-round config changes
- **4-phase draws**: Splits expensive operations across multiple transactions
- **Swap-and-pop registration**: O(1) add/remove for participant tracking
- **Commit-reveal randomness**: Uses Flow's native `RandomConsumer` for tamper-proof randomness
- **Resource-oriented**: Each Round, BatchSelectionData, and PrizeDrawReceipt is a Cadence resource with clear lifecycle

---

## 3. Shares Model (ERC4626)

User balances are tracked via **shares**, not raw token amounts. This is the same model used by ERC4626 vaults in the Ethereum ecosystem.

### Why Shares?

In a naive system, distributing yield to 10,000 users requires 10,000 state updates. With shares, it takes **one**:

```
// O(1): Single state update distributes yield to ALL users
totalAssets += yieldAmount

// Each user's balance automatically increases:
userBalance = userShares × (totalAssets / totalShares)
```

### Core Formulas

```
Share Price    = (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
Shares Minted  = depositAmount × (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
Asset Value    = userShares × (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
```

Where `VIRTUAL_SHARES = 0.0001` and `VIRTUAL_ASSETS = 0.0001`.

### Virtual Offset (Donation Attack Protection)

The virtual offset prevents the "inflation attack" — a known ERC4626 vulnerability where a malicious first depositor can steal subsequent deposits via share price manipulation. By adding virtual shares and assets, the share price starts near 1:1 and cannot be manipulated when the pool is small.

### State Changes by Operation

| Operation | totalShares | totalAssets | Share Price |
|-----------|-------------|-------------|-------------|
| Deposit | + shares minted | + deposit amount | Unchanged |
| Withdraw | - shares burned | - withdrawn amount | Unchanged |
| Yield Accrual | Unchanged | + yield amount | Increases |
| Deficit | Unchanged | - loss amount | Decreases |

### Why Process Yield Before Deposit?

The contract always syncs with the yield source **before** processing a deposit. Without this, new depositors would get shares at a stale (lower) price and effectively steal yield from existing users:

```
Before: totalAssets = 100, totalShares = 100, sharePrice = 1.0
Unprocessed yield: 10

WITHOUT syncing first:
  Deposit 100 → mints 100 shares
  Then sync: totalAssets = 210, totalShares = 200
  New user owns: 100/200 × 210 = 105 (stole 5 from existing users)

WITH syncing first:
  Sync: totalAssets = 110, sharePrice = 1.1
  Deposit 100 → mints 100/1.1 ≈ 90.9 shares
  New user owns: 90.9/190.9 × 210 = 100 (correct)
```

---

## 4. Yield Distribution

### How Yield Gets Into the System

Tokens deposited into the pool are forwarded to an external **yield source** (e.g., FlowYieldVaults). This yield source invests the tokens and generates returns. The contract doesn't know about yield in real-time — it discovers it by comparing the yield source balance to what it has tracked internally.

### The Sync Process

`syncWithYieldSource()` is called automatically before deposits, withdrawals, and draws:

```
yieldSourceBalance = yieldConnector.minimumAvailable()
allocatedFunds = userPoolBalance + allocatedPrizeYield + allocatedProtocolFee

if yieldSourceBalance > allocatedFunds → excess yield (distribute)
if yieldSourceBalance < allocatedFunds → deficit (absorb losses)
if yieldSourceBalance == allocatedFunds → nothing to do
```

### Three-Way Split

When excess yield is discovered, it's split via a configurable `DistributionStrategy`:

```cadence
struct FixedPercentageStrategy {
    rewardsPercent: UFix64    // e.g., 0.35 (35%)
    prizePercent: UFix64      // e.g., 0.65 (65%)
    protocolFeePercent: UFix64 // e.g., 0.0 (0%)
}
```

Example with 100 tokens of yield at 35/65/0 split:
- **35 tokens → Rewards**: `ShareTracker.accrueYield(35)` increases `totalAssets`, raising share price for all depositors
- **65 tokens → Prize**: Added to `allocatedPrizeYield`, stays in yield source until draw time
- **0 tokens → Protocol Fee**: Would be added to `allocatedProtocolFee`

### Where Funds Actually Live

**All funds stay in the yield source** until they need to move:

| Allocation | Tracked In | When Materialized |
|------------|-----------|-------------------|
| User rewards | `userPoolBalance` via ShareTracker | On withdrawal (user gets tokens) |
| Prize pool | `allocatedPrizeYield` | At draw time (withdrawn from yield source → prize pool) |
| Protocol fee | `allocatedProtocolFee` | At draw time (forwarded to recipient or unclaimed vault) |

This ensures the accounting invariant (`allocatedFunds == yieldSourceBalance`) always holds after sync.

### Dust Handling

When yield is accrued to the ShareTracker, a tiny amount goes to the virtual shares (the "dead" ownership). This dust is routed to the protocol fee rather than being lost:

```
effectiveShares = totalShares + VIRTUAL_SHARES
dustAmount = yieldAmount × VIRTUAL_SHARES / effectiveShares
actualRewards = yieldAmount - dustAmount
```

---

## 5. TWAB (Time-Weighted Average Balance)

TWAB determines each user's prize odds. It measures **balance × time** — a user holding 100 tokens for the full round has 10x the weight of someone holding 100 tokens for 1/10th of the round.

### Why Not Just Use Balance?

Without time-weighting, a whale could deposit right before a draw, dominate the odds, win, and immediately withdraw. TWAB makes this uneconomical:

```
Honest user:  100 tokens × 7 days  = weight 100
Whale attack: 10,000 tokens × 1 hr = weight ≈ 0.6

The whale has 100x the balance but only 0.6% of the weight.
```

### How It Works (Cumulative Tracking)

Rather than projecting future TWAB, the contract accumulates **actual share-seconds** as they happen:

```
On every deposit/withdraw:
  1. Accumulate pending share-seconds: oldShares × (now - lastUpdateTime)
  2. Update the stored snapshot: lastUpdateTime = now, storedShares = newShares

At draw time:
  finalTWAB = accumulated + currentShares × (roundEndTime - lastUpdateTime)
```

This is **duration-independent** — if an admin changes the round duration mid-round, no stored values become invalid because nothing references the duration until finalization.

### Lazy Initialization

Users who deposit once and never interact again still get fair TWAB. If a user has no TWAB record in the current round, the system falls back to:

```
TWAB = currentShares × (roundEndTime - roundStartTime)
```

This gives them full-round credit for their current share balance — correct because they held those shares the entire round.

### Normalization

TWAB values are divided by `actualRoundDuration` to produce **entries** (human-readable prize weight):

```
entries = finalTWAB / actualRoundDuration
```

A user holding 100 shares for the full round gets entries = 100. A user holding 100 shares for half the round gets entries = 50.

### Bonus Weights

Admins can grant bonus prize weight for promotions:

```cadence
Admin.setBonusLotteryWeight(poolID, receiverID, bonusWeight: 5.0, reason: "Launch promo")
```

A bonus of 5.0 is equivalent to holding 5 additional tokens for the entire round. Bonus weight is additive to TWAB weight during winner selection.

---

## 6. Rounds & the Draw Cycle

### Round Lifecycle

Each pool runs in **rounds** — discrete periods during which TWAB accumulates and prizes build up. Rounds are separate `Round` resources, each with their own TWAB dictionaries.

```
Round 1 starts → users deposit/withdraw, TWAB accumulates
Round 1 target end time passes → round can be drawn (but continues until startDraw())
startDraw() called → Round 1 moves to "pending draw", Round 2 starts immediately
Draw processing happens → winners selected from Round 1's TWAB
completeDraw() called → Round 1 destroyed, Round 2 continues
```

### The "Gap Period"

The time between a round's `targetEndTime` and when `startDraw()` is actually called is the **gap period**. Users who deposit during the gap are handled automatically: their shares are finalized in the ending round at their pre-transaction balance, and the new round uses lazy initialization to give them full credit.

### 4-Phase Draw Process

Drawing is split into 4 phases to avoid O(n) bottlenecks in a single transaction:

#### Phase 1: `startDraw()`
 
- Sets `actualEndTime` on the ending round
- Moves ending round to `pendingDrawRound`
- Creates a new `Round` for the next period (users unblocked immediately)
- Creates `BatchSelectionData` with a snapshot of all registered receivers
- Requests on-chain randomness from Flow's `RandomConsumer`
- Materializes prize yield (withdraws `allocatedPrizeYield` from yield source into prize pool)
- Materializes and forwards protocol fees

#### Phase 2: `processDrawBatch(limit)` (called N times)

- Processes `limit` receivers from the snapshot
- For each receiver: finalizes their TWAB weight, adds bonus weight
- Builds cumulative weight array for binary search
- Tracks progress via cursor — can be called repeatedly until all receivers processed
- Users can continue depositing/withdrawing in the new round during this phase

#### Phase 3: `requestDrawRandomness()` (removed — now happens in Phase 1)

Note: In the current implementation, randomness is requested during `startDraw()`. The commit block is recorded in the `PrizeDrawReceipt`.

#### Phase 4: `completeDraw()`

- Must be called in a **different block** from `startDraw()` (randomness security)
- Fulfills the randomness request (Flow's `RandomConsumer` derives it from future blocks)
- Selects winners using weighted random selection
- Distributes token prizes (auto-compounded) and NFT prizes (pending claim)
- Destroys the pending draw round
- Emits `PrizesAwarded` with winners, amounts, and addresses

### Pool States

```
ROUND_ACTIVE    → Normal operation, deposits/withdrawals/TWAB accumulation
AWAITING_DRAW   → startDraw() called, waiting for batch processing
DRAW_PROCESSING → processDrawBatch() in progress, or waiting for completeDraw()
INTERMISSION    → completeDraw() finished, transitioning back to ROUND_ACTIVE
```

Deposits and withdrawals are allowed in **all states** (except emergency). Only unregistration is blocked during draws to prevent index corruption.

---

## 7. Winner Selection & Randomness

### Randomness (Commit-Reveal)

The contract uses Flow's native `RandomConsumer` for tamper-proof randomness:

1. **Commit (Phase 1)**: `startDraw()` calls `randomConsumer.requestRandomness()`, which records the current block height as the "commit block"
2. **Reveal (Phase 4)**: `completeDraw()` calls `randomConsumer.fulfillRandomRequest()`, which derives randomness from blocks **after** the commit block

This ensures:
- The admin cannot predict or influence the random number (it depends on future blocks)
- The random number cannot be manipulated by transaction ordering
- At least 1 block must pass between commit and reveal

### PRNG (Xorshift128plus)

The single random seed from Flow is expanded into a deterministic stream using `Xorshift128plus`, a fast, statistically-sound PRNG. This allows selecting multiple winners from one seed.

### Weighted Selection Algorithm

Winners are chosen via **weighted random selection without replacement**:

1. **Build cumulative weight array** (during `processDrawBatch()`):
   ```
   receiver:          [A,   B,    C,    D   ]
   weight:            [10,  30,   5,    55  ]
   cumulativeWeight:  [10,  40,   45,   100 ]
   ```

2. **Generate random value** from PRNG, scaled to [0, totalWeight):
   ```
   randomValue = (prng.nextUInt64() % SCALING_FACTOR) / SCALING_DIVISOR × totalWeight
   ```

3. **Binary search** for the winner:
   ```
   randomValue = 37 → binary search finds index 1 (cumulativeWeight[1] = 40 > 37)
   Winner = receiver B
   ```

4. **Rejection sampling** for multiple winners (no duplicates):
   - If the selected winner was already picked, generate a new random value
   - Maximum retries: `receiverCount × 3`
   - Fallback: if max retries exceeded, fill remaining slots with unselected participants

### Edge Cases

- **0 total weight**: Falls back to unweighted selection (first N participants)
- **1 receiver**: That receiver wins automatically
- **0 receivers**: No winners, prizes roll over to next draw

---

## 8. Prize Distribution

### Distribution Types

The contract supports pluggable prize distribution strategies:

#### SingleWinnerPrize

One winner takes the entire prize pool:

```
Total prize: 100 tokens
Winner 1: 100 tokens + all NFT prizes
```

#### PercentageSplit

Split among N winners by percentage (must sum to 100%):

```
Example: [50%, 30%, 20%]
Total prize: 100 tokens
Winner 1: 50 tokens
Winner 2: 30 tokens
Winner 3: 20 tokens
```

#### FixedAmountTiers

Multiple tiers with fixed amounts and winner counts:

```
Tier 1 "Grand Prize":  1 winner  × 50 tokens + rare NFT
Tier 2 "Runner Up":    3 winners × 10 tokens each
Tier 3 "Lucky Draw":   10 winners × 2 tokens each
Total: 100 tokens, 14 winners
```

### Auto-Compounding

Token prizes are **not** sent to the winner as a separate transfer. Instead, they are:

1. Withdrawn from the prize pool
2. Deposited back into the yield source
3. Credited as new shares to the winner's balance
4. TWAB updated in the current active round

This means prize winnings immediately start earning yield and contributing to future prize odds. The winner's share balance increases, and the `PrizesAwarded` event records the amounts.

---

## 9. Deficit Handling

### What Causes a Deficit?

A deficit occurs when the yield source balance is **less** than what the contract has allocated. This can happen from:
- Yield source protocol losses (slashing, bad debt, exploit)
- Rounding errors in the yield source's internal math
- External market conditions

### Deficit Waterfall (Priority Order)

Losses are absorbed in this order to **protect user principal**:

```
1. PROTOCOL FEE absorbs first
   → Protocol revenue takes the first hit
   → Capped by allocatedProtocolFee (can't go negative)
   → Any shortfall cascades down

2. PRIZE POOL absorbs second
   → Prize pool takes its share + protocol shortfall
   → Capped by allocatedPrizeYield
   → Any shortfall cascades down

3. USER REWARDS absorbs last
   → Share price decreases (totalAssets reduced)
   → This is the only case where user balances decrease
   → Only happens after protocol and prize buffers are exhausted
```

### Example

```
State:
  userPoolBalance = 103
  allocatedPrizeYield = 3
  allocatedProtocolFee = 4
  allocatedFunds = 110

Yield source reports only 90 (deficit of 20):
  Strategy: 30% rewards, 30% prize, 40% protocol

  Step 1: Protocol absorbs (has 4, target 8) → absorbs 4, shortfall 4
  Step 2: Prize absorbs (has 3, target 6 + 4 shortfall = 10) → absorbs 3, shortfall 7
  Step 3: Rewards absorbs (target 6 + 7 shortfall = 13) → totalAssets decreases by 13

Result: allocatedFunds = 90 = yieldSourceBalance (invariant restored)
```

### Design Philosophy

Protocol fee and prize pool act as **buffers** that absorb losses before user principal is affected. This prioritizes user trust — the protocol takes losses before its users do.

---

## 10. Emergency System

### Emergency States

| State | Deposits | Withdrawals | Draws | Purpose |
|-------|----------|-------------|-------|---------|
| **Normal** | Allowed | Allowed | Allowed | Normal operation |
| **Paused** | Blocked | Blocked | Blocked | Full stop (maintenance, critical bug) |
| **EmergencyMode** | Blocked | Allowed | Blocked | Yield source problem — let users exit |
| **PartialMode** | Limited | Allowed | Blocked | Degraded operation (deposit caps) |

### Health Score

The contract monitors yield source health on a 0.0–1.0 scale:

```
Health Score = (balanceHealth × 0.5) + (withdrawalHealth × 0.5)

balanceHealth = 0.5 if yieldSourceBalance ≥ userPoolBalance × minBalanceThreshold, else 0
withdrawalHealth = 0.5 × (1 / (consecutiveWithdrawFailures + 1))
```

### Auto-Trigger

Emergency mode activates automatically when:
- Health score drops below `minYieldSourceHealth` (default: 0.5)
- Consecutive withdrawal failures reach `maxWithdrawFailures` (default: 3)

### Auto-Recovery

Emergency mode can auto-recover when:
- Health score returns to 0.9+ (full recovery), OR
- `maxEmergencyDuration` exceeded AND health score meets `minRecoveryHealth` (time-based recovery)

### Valid State Transitions

```
Normal ←→ EmergencyMode  (auto-trigger / auto-recover / manual)
Normal ←→ Paused         (manual only)
Normal ←→ PartialMode    (manual only)
```

### Emergency Config (Defaults)

| Setting | Default | Description |
|---------|---------|-------------|
| `maxEmergencyDuration` | 86,400s (24h) | Max time in emergency before time-based recovery |
| `autoRecoveryEnabled` | true | Whether auto-recovery is active |
| `minYieldSourceHealth` | 0.5 | Health below this triggers emergency |
| `maxWithdrawFailures` | 3 | Consecutive failures before emergency |
| `partialModeDepositLimit` | 100.0 | Deposit cap in partial mode |
| `minBalanceThreshold` | 0.95 | Balance ratio for health calculation |
| `minRecoveryHealth` | 0.5 | Minimum health for time-based recovery |

---

## 11. Registration & Unregistration

### Data Structure

The pool maintains two parallel structures for tracking participants:

```
registeredReceivers: {receiverID → index}     // O(1) lookup
registeredReceiverList: [receiverID, ...]      // O(n) iteration for batch processing
```

### Registration

On first deposit, a user is automatically registered:
- Appended to `registeredReceiverList`
- Index stored in `registeredReceivers` map
- TWAB tracking begins in the active round

### Unregistration (Swap-and-Pop)

When a user withdraws their entire balance, they're removed via **swap-and-pop** — an O(1) algorithm:

```
registeredReceiverList = [A, B, C, D, E]
Remove C (index 2):
  1. Swap C with last element E: [A, B, E, D, E]
  2. Remove last:                 [A, B, E, D]
  3. Update E's index: registeredReceivers[E] = 2
  4. Remove C from map
```

### Why Unregistration Is Blocked During Draws

`processDrawBatch()` iterates through `registeredReceiverList` using a cursor. If swap-and-pop runs during iteration:
- If the swap target is **before** the cursor: it gets processed twice
- If the swap target is **after** the cursor: it gets skipped

To prevent this, users who withdraw to zero during a draw become **ghost receivers** (0 shares, 0 weight). They're cleaned up after the draw via `cleanupStaleEntries()`.

---

## 12. Slippage Protection

When tokens are deposited into the yield source, the yield source may return slightly fewer tokens than sent (due to internal rounding). The `maxSlippageBps` parameter protects against this:

```
minAcceptable = nominalDeposit × (10000 - maxSlippageBps) / 10000

Example:
  Deposit: 1000 tokens
  maxSlippageBps: 100 (1%)
  minAcceptable: 1000 × 9900 / 10000 = 990 tokens

  If yield source returns < 990 tokens → transaction reverts
```

Recommended default: `100` bps (1%) for normal conditions.

---

## 13. Sponsor Positions

Sponsors are participants who deposit tokens and earn yield but are **not eligible** for prizes. They use a separate `SponsorPositionCollection` resource.

### Why Sponsors?

- **Boost the prize pool**: Sponsor deposits generate yield that feeds the prize pool, making prizes larger for regular users
- **Protocol treasuries**: The protocol can deposit its own funds as a sponsor to seed the pool
- **Institutional participants**: Entities that want yield but don't need/want lottery participation

### How Sponsors Differ

| Aspect | User (PoolPositionCollection) | Sponsor (SponsorPositionCollection) |
|--------|-------------------------------|-------------------------------------|
| Prize eligible | Yes | No |
| Earns rewards yield | Yes | Yes |
| TWAB tracking | Yes | No |
| Appears in draw | Yes | No |
| `getPoolEntries()` | TWAB-based weight | Always 0.0 |

Sponsors share the same ShareTracker as regular users — their deposits increase `totalShares` and `totalAssets` the same way. They earn the same share price appreciation. They're simply excluded from the TWAB-weighted draw.

---

## 14. NFT Prizes

The contract supports **non-fungible token (NFT) prizes** alongside token prizes.

### Lifecycle

1. **Deposit**: Admin deposits an NFT into the pool's available prize vault
2. **Assignment**: During pool configuration, NFTs are assigned to prize tiers (e.g., the grand prize winner gets a specific NFT)
3. **Award**: When `completeDraw()` runs, winning NFTs are moved to the winner's **pending claims** queue
4. **Claim**: The winner calls `claimPendingNFT()` to take ownership of the NFT

### Why Pending Claims?

Unlike token prizes (which are auto-compounded), NFTs cannot be merged into a share balance. They must be explicitly claimed by the winner, who needs an appropriate NFT collection in their account storage. The pending queue holds them safely until the user is ready.

### Query Functions

```cadence
pool.getAvailableNFTPrizeIDs()         // NFTs available for current draw
pool.getPendingNFTCount(receiverID)    // How many NFTs a user can claim
pool.getPendingNFTIDs(receiverID)      // Which NFTs a user can claim
```

---

## 15. Direct Pool Funding

Admins can inject tokens directly into a pool via `Admin.fundPoolDirect()`, targeting either:

### Rewards (Share Price Increase)

Tokens are deposited into the yield source and accrued to the ShareTracker, raising the share price for all depositors. Requires at least one depositor (otherwise funds would be orphaned to virtual shares).

### Prize Pool

Tokens are deposited into the yield source and tracked as `allocatedPrizeYield`. They become available in the next draw's prize pool.

### Use Cases

- **Launch bonus**: Seed the prize pool before enough yield has accumulated
- **Marketing sponsorship**: External sponsors fund prizes directly
- **Promotional events**: Boost a specific draw's prize pool
- **Yield subsidy**: Increase share price directly during low-yield periods

---

## 16. Protocol Fees

### How Fees Accumulate

Protocol fees come from the yield distribution split. If the strategy allocates 10% to protocol fees, 10% of each yield sync goes to `allocatedProtocolFee`.

### Materialization

At draw time, accumulated protocol fees are withdrawn from the yield source and:
- **If a recipient is configured**: Forwarded to the recipient's FungibleToken.Receiver capability
- **If no recipient**: Stored in the pool's `unclaimedProtocolFeeVault`

The admin can withdraw unclaimed fees at any time via `Admin.withdrawUnclaimedProtocolFee()`.

### Rounding Dust

The virtual offset in the ShareTracker causes tiny amounts of yield to go to "virtual shares" (dead ownership). This dust is routed to protocol fees rather than being lost, tracked via the `RewardsRoundingDustToProtocolFee` event.

### Setting the Recipient

```cadence
Admin.setPoolProtocolFeeRecipient(poolID, recipientCap)
```

Requires `OwnerOnly` entitlement — this **cannot** be delegated as a capability. Only the account that deployed the contract can set the recipient.

---

## 17. Key Invariants

These must always hold:

1. **Allocated Funds = Yield Source Balance** (after every sync)
   ```
   userPoolBalance + allocatedPrizeYield + allocatedProtocolFee == yieldSource.minimumAvailable()
   ```

2. **Sum of User Share Values = Total Assets**
   ```
   Σ(convertToAssets(userShares[id])) ≈ totalAssets  (within rounding)
   ```

3. **TWAB Safety Cap**
   ```
   normalizedWeight ≤ shares  (user can't have more weight than shares)
   ```

4. **Share Price Stability**
   ```
   sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)
   Deposits and withdrawals don't change share price (only yield/deficit does)
   ```

5. **No Negative Balances**
   ```
   totalShares ≥ 0, totalAssets ≥ 0, userShares[id] ≥ 0
   allocatedPrizeYield ≥ 0, allocatedProtocolFee ≥ 0
   ```

---

## 18. Entitlements & Access Control

Cadence uses **entitlements** to restrict access to sensitive operations:

| Entitlement | Who | Operations |
|-------------|-----|-----------|
| `PositionOps` | Users / Sponsors | `deposit()`, `withdraw()`, `claimPendingNFT()` |
| `ConfigOps` | Admin | Non-destructive config: minimum deposit, draw interval, NFT deposit |
| `CriticalOps` | Admin | Draws, emergency mode, strategy changes, direct funding |
| `OwnerOnly` | Account owner only | Protocol fee recipient (cannot be delegated as a capability) |

### Why OwnerOnly?

`OwnerOnly` protects the most sensitive operation — setting where protocol fees go. Unlike other entitlements which can be granted via capabilities, `OwnerOnly` requires direct storage access to the account. This prevents even a compromised admin capability from redirecting fees.

---

## 19. User Lifecycle Summary

### Setup (One-Time)

1. Create a `PoolPositionCollection` resource and save to account storage
2. Ensure you have a vault for the pool's token type (e.g., pyUSD)

### Deposit

```cadence
collection.deposit(poolID, from: <-tokenVault, maxSlippageBps: 100)
```

- Auto-registers with pool on first deposit
- Auto-syncs yield source before processing
- Receives shares at current share price
- TWAB tracking begins in current round

### Earn (Passive)

- Share price rises as yield accrues (visible after next sync)
- TWAB weight accumulates for prize odds
- No user action required

### Withdraw

```cadence
let tokens <- collection.withdraw(poolID, amount: withdrawAmount)
```

- Auto-syncs before processing
- Returns tokens at current share price (principal + rewards)
- **Dust threshold**: If remaining balance < `minimumDeposit / 10`, full withdrawal triggered
- **Actual may differ from requested** due to yield source rounding

### Win Prizes

- Token prizes: Auto-compounded (no action needed, balance increases)
- NFT prizes: Must call `collection.claimPendingNFT(poolID, nftIndex)`

---

## 20. Query Reference

### Contract-Level Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `borrowPool(poolID)` | `&Pool?` | Get pool reference |
| `getAllPoolIDs()` | `[UInt64]` | All pool IDs |
| `isRoundActive(poolID)` | `Bool` | Round is live |
| `isAwaitingDraw(poolID)` | `Bool` | Waiting for draw start |
| `isDrawInProgress(poolID)` | `Bool` | Draw in progress |
| `isInIntermission(poolID)` | `Bool` | Between rounds |
| `getUserEntries(poolID, receiverID)` | `UFix64` | User's prize weight |
| `getDrawProgressPercent(poolID)` | `UFix64` | Batch progress (0–100) |
| `getTimeUntilNextDraw(poolID)` | `UFix64` | Seconds until draw eligible |

### Pool-Level Query Functions

**User Balances:**

| Function | Returns |
|----------|---------|
| `getUserAssetValue(receiverID)` | Balance based on last sync |
| `getReceiverTotalBalance(receiverID)` | Same as above |
| `getReceiverTotalEarnedPrizes(receiverID)` | Lifetime prize winnings |
| `getUserShares(receiverID)` | Raw share count |
| `getUserEntries(receiverID)` | TWAB-based prize weight |
| `getBonusWeight(receiverID)` | Admin bonus weight |
| `getReceiverOwnerAddress(receiverID)` | Wallet address |
| `isReceiverRegistered(receiverID)` | In pool? |
| `isSponsor(receiverID)` | Prize-ineligible? |

**Pool Stats:**

| Function | Returns |
|----------|---------|
| `getSharePrice()` | Current share price |
| `getTotalShares()` | Total shares outstanding |
| `getTotalAssets()` | Total assets in share system |
| `getTotalDistributed()` | Cumulative rewards distributed |
| `getRegisteredReceiverCount()` | Number of depositors |
| `getSponsorCount()` | Number of sponsors |
| `getConfig()` | Full pool configuration |

**Yield & Allocations:**

| Function | Returns |
|----------|---------|
| `getYieldSourceBalance()` | Actual yield source balance |
| `getTotalAllocatedFunds()` | Sum of all allocations |
| `getUserPoolBalance()` | User rewards in yield source |
| `getAllocatedPrizeYield()` | Pending prize allocation |
| `getAllocatedProtocolFee()` | Pending protocol fee |
| `getAvailableYieldRewards()` | Unprocessed yield |
| `needsSync()` | Has unsynced yield? |
| `getDistributionStrategyName()` | Strategy description |

**Prize Pool:**

| Function | Returns |
|----------|---------|
| `getPrizePoolBalance()` | Materialized prize tokens |
| `getDirectPrizeFundingThisDraw()` | Admin-funded amount |
| `getPrizeRound()` | Current round number |
| `getAvailableNFTPrizeIDs()` | NFTs for current draw |
| `getPendingNFTCount(receiverID)` | User's unclaimed NFTs |
| `getPendingNFTIDs(receiverID)` | Which NFTs to claim |

**Round/Draw State:**

| Function | Returns |
|----------|---------|
| `isRoundActive()` | Round is live |
| `isRoundEnded()` | Past target end time |
| `canDrawNow()` | Ready for startDraw() |
| `isDrawInProgress()` | Draw underway |
| `isBatchComplete()` | All users processed |
| `isReadyForDrawCompletion()` | Ready for completeDraw() |
| `getCurrentRoundID()` | Current round number |
| `getCurrentRoundTargetEndTime()` | When round becomes drawable |
| `getRoundStartTime()` | When round started |
| `getRoundDuration()` | Configured duration (seconds) |
| `getRoundElapsedTime()` | Seconds elapsed |
| `getDrawBatchProgress()` | Detailed progress map |

**Emergency:**

| Function | Returns |
|----------|---------|
| `getEmergencyState()` | Current state enum |
| `isEmergencyMode()` | Withdrawals-only mode? |
| `isPartialMode()` | Limited operation? |
| `getEmergencyConfig()` | Thresholds and settings |
| `getEmergencyInfo()` | Detailed state info |

**Share Conversion (Preview):**

| Function | Returns |
|----------|---------|
| `convertToShares(assets)` | Shares for deposit amount |
| `convertToAssets(shares)` | Tokens for share amount |
| `previewDeposit(amount)` | Shares user would receive |
| `previewRedeem(shares)` | Tokens user would receive |

---

## 21. Events Reference

### User Activity

| Event | Key Fields |
|-------|-----------|
| `Deposited` | `poolID, receiverID, amount, shares, ownerAddress` |
| `SponsorDeposited` | `poolID, receiverID, amount, shares, ownerAddress` |
| `Withdrawn` | `poolID, receiverID, requestedAmount, actualAmount, ownerAddress` |
| `DepositSlippage` | `poolID, nominalAmount, actualReceived, slippage` |
| `WithdrawalFailure` | `poolID, receiverID, amount, consecutiveFailures, yieldAvailable` |

### Yield & Rewards

| Event | Key Fields |
|-------|-----------|
| `RewardsProcessed` | `poolID, totalAmount, rewardsAmount, prizeAmount` |
| `RewardsYieldAccrued` | `poolID, amount` |
| `DeficitApplied` | `poolID, totalDeficit, absorbedByProtocolFee, absorbedByPrize, absorbedByRewards` |
| `InsolvencyDetected` | `poolID, unreconciledAmount` |
| `RewardsRoundingDustToProtocolFee` | `poolID, amount` |

### Draw Cycle

| Event | Key Fields |
|-------|-----------|
| `DrawBatchStarted` | `poolID, endedRoundID, newRoundID, totalReceivers` |
| `DrawBatchProcessed` | `poolID, processed, remaining` |
| `DrawRandomnessRequested` | `poolID, totalWeight, prizeAmount, commitBlock` |
| `PrizesAwarded` | `poolID, winners, winnerAddresses, amounts, round` |
| `IntermissionStarted` | `poolID, completedRoundID, prizePoolBalance` |
| `IntermissionEnded` | `poolID, newRoundID, roundDuration` |

### Prize & Funding

| Event | Key Fields |
|-------|-----------|
| `PrizePoolFunded` | `poolID, amount, source` |
| `DirectFundingReceived` | `poolID, destination, destinationName, amount, purpose, metadata` |
| `ProtocolFeeForwarded` | `poolID, amount, recipient` |
| `ProtocolFeeFunded` | `poolID, amount, source` |

### NFT Prizes

| Event | Key Fields |
|-------|-----------|
| `NFTPrizeDeposited` | `poolID, nftID, nftType` |
| `NFTPrizeAwarded` | `poolID, receiverID, nftID, nftType, round, ownerAddress` |
| `NFTPrizeClaimed` | `poolID, receiverID, nftID, nftType, ownerAddress` |
| `NFTPrizeStored` | `poolID, receiverID, nftID, nftType, reason, ownerAddress` |
| `NFTPrizeWithdrawn` | `poolID, nftID, nftType` |

### Admin Configuration

| Event | Key Fields |
|-------|-----------|
| `PoolCreated` | `poolID, assetType, strategy` |
| `DistributionStrategyUpdated` | `poolID, oldStrategy, newStrategy` |
| `PrizeDistributionUpdated` | `poolID, oldDistribution, newDistribution` |
| `MinimumDepositUpdated` | `poolID, oldMinimum, newMinimum` |
| `FutureRoundsIntervalUpdated` | `poolID, oldInterval, newInterval` |
| `RoundTargetEndTimeUpdated` | `poolID, roundID, oldTarget, newTarget` |
| `ProtocolFeeRecipientUpdated` | `poolID, newRecipient` |
| `PoolStorageCleanedUp` | `poolID, ghostReceiversCleaned, userSharesCleaned, ...` |

### Bonus Weights

| Event | Key Fields |
|-------|-----------|
| `BonusPrizeWeightSet` | `poolID, receiverID, bonusWeight, reason, timestamp` |
| `BonusPrizeWeightAdded` | `poolID, receiverID, additionalWeight, newTotalBonus, reason` |
| `BonusPrizeWeightRemoved` | `poolID, receiverID, previousBonus` |

### Emergency

| Event | Key Fields |
|-------|-----------|
| `PoolPaused` | `poolID, reason` |
| `PoolUnpaused` | `poolID` |
| `PoolEmergencyEnabled` | `poolID, reason, timestamp` |
| `PoolEmergencyDisabled` | `poolID, timestamp` |
| `PoolPartialModeEnabled` | `poolID, reason, timestamp` |
| `EmergencyModeAutoTriggered` | `poolID, reason, healthScore, timestamp` |
| `EmergencyModeAutoRecovered` | `poolID, reason, healthScore, duration, timestamp` |
| `WeightWarningThresholdExceeded` | `poolID, totalWeight, warningThreshold, percentOfMax` |

---

## 22. Deployment

| Network | Contract Address | Token | Status |
|---------|-----------------|-------|--------|
| Emulator | `0xf8d6e0586b0a20c7` | FlowToken | Development |
| Testnet | `0xc24c9fd9b176ea87` | FlowToken | Testing |
| Mainnet | `0xa092c4aab33daeda` | pyUSD | Live |

### Storage Paths

| Constant | Description |
|----------|-------------|
| `PoolPositionCollectionStoragePath` | User's position collection |
| `PoolPositionCollectionPublicPath` | Public capability for user collection |
| `SponsorPositionCollectionStoragePath` | Sponsor's position collection |
| `SponsorPositionCollectionPublicPath` | Public capability for sponsor collection |
| `AdminStoragePath` | Admin resource (deployer only) |

### Contract Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `VIRTUAL_SHARES` | 0.0001 | Virtual offset for share price |
| `VIRTUAL_ASSETS` | 0.0001 | Virtual offset for share price |
| `MINIMUM_DISTRIBUTION_THRESHOLD` | 0.000001 | Min yield to distribute |
| `SAFE_MAX_TVL` | 147,500,000,000 | Safe maximum TVL |
| `MAX_BONUS_WEIGHT_PER_USER` | 14,750,000,000 | Max bonus per user |
