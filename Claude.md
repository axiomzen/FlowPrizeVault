# FlowPrizeVault - Claude Context Guide

This document provides context for AI assistants working with the FlowPrizeVault codebase.

## Project Overview

**FlowPrizeVault** is a **no-loss lottery / prize-linked savings protocol** built on the **Flow Blockchain** using **Cadence**. Users deposit tokens to earn guaranteed savings interest while having chances to win lottery prizes funded by aggregated yield.

**Key Value Proposition**: Users deposit funds into a yield-generating vault. The generated yield is split between:
- **Savings** (auto-compounds into user deposits)
- **Lottery prizes** (distributed to winners via random draws)
- **Treasury** (protocol fees)

Users can withdraw anytime, making it "lossless" - they don't risk their principal to participate.

**Status**: Under security audit

---

## Repository Structure

```
FlowPrizeVault/
├── cadence/
│   ├── contracts/
│   │   ├── PrizeSavings.cdc          # Main protocol contract (~5,500 lines)
│   │   ├── PrizeWinnerTracker.cdc    # Optional winner history tracking
│   │   └── mock/                      # Testing contracts
│   ├── scripts/                       # Read-only queries (44 scripts)
│   │   ├── prize-savings/            # User-facing (13)
│   │   └── test/                     # Debug/test (31)
│   ├── transactions/                  # State-changing ops (74 transactions)
│   │   ├── prize-savings/            # User & admin (23)
│   │   └── test/                     # Testing (48)
│   ├── tests/                        # Cadence unit tests (28 files)
│   └── long_tests/                   # Extended stress tests
├── imports/                          # External contract dependencies (20+)
├── docs/
│   ├── ACCOUNTING.md                 # Shares model & accounting details
│   └── TWAB.md                       # Time-weighted average balance mechanics
├── flow.json                         # Flow CLI configuration
├── Makefile                          # Test runner commands
└── test_prize_savings.py             # Python integration tests
```

---

## Core Architecture

### Main Contract: `PrizeSavings.cdc`

The contract is organized into these key resources:

```
PrizeSavings (Contract)
├── Admin                    # Privileged operations (pool creation, config, draws)
├── Pool                     # Core prize savings pool
│   ├── ShareTracker         # ERC4626-style share accounting
│   ├── LotteryDistributor   # Prize pool and NFT management
│   ├── Round                # Per-round TWAB tracking
│   └── RandomConsumer       # On-chain randomness
├── PoolPositionCollection   # User's lottery-eligible position
├── SponsorPositionCollection # User's lottery-ineligible position
└── BatchSelectionData       # Lottery winner selection data
```

### Key Design Patterns

1. **ERC4626-Style Shares**: O(1) yield distribution via share price appreciation
2. **Normalized TWAB**: Fair lottery odds based on time-weighted average balance
3. **Virtual Offset Protection**: Prevents ERC4626 inflation/donation attacks
4. **Batch Processing**: Supports large user counts without gas limits
5. **Resource-Based Access Control**: Entitlements for fine-grained permissions

---

## Accounting Model

### Three-Way Yield Split

Yield from the connected DeFi source is distributed according to a configurable strategy:

```
Total Yield
    ↓
DistributionStrategy.calculateDistribution()
    ↓
┌────────────┬──────────────┬─────────────┐
│  Savings   │   Lottery    │  Treasury   │
│ (e.g. 40%) │  (e.g. 40%)  │  (e.g. 20%) │
└────────────┴──────────────┴─────────────┘
     ↓              ↓              ↓
 Share price   Prize pool    Protocol fees
 increases     funded         forwarded
```

### Key Accounting Variables

```cadence
// Pool-level allocations (must sum to yield source balance after sync)
allocatedSavings       // User portion: deposits + prizes + accrued savings
allocatedLotteryYield  // Lottery portion: awaiting transfer to prize pool
allocatedTreasuryYield // Treasury portion: awaiting transfer to recipient

// Share tracking
totalShares            // Total shares outstanding
totalAssets            // Total value backing shares (determines share price)
userShares[receiverID] // Per-user share balances
```

### Share Price Formula (with virtual offset)

```
sharePrice = (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
           = (totalAssets + 0.0001) / (totalShares + 0.0001)
```

---

## TWAB (Time-Weighted Average Balance)

### Purpose

Prevents manipulation where users deposit large amounts just before a draw to gain unfair lottery odds.

### How It Works

1. **Track share-seconds**: `weight = shares × time_held`
2. **Normalize by duration**: `normalized_weight = shares × (elapsed / roundDuration)`
3. **Result**: Users who hold longer get proportionally higher lottery odds

### Example

```
User A: 100 shares for full 7-day round  → weight = 100 (average shares)
User B: 100 shares deposited halfway     → weight = 50  (prorated)
User C: 1000 shares deposited at end     → weight ≈ 0   (no time credit)
```

---

## Draw Process (4 Phases)

```
Phase 1: startDraw()
├── Move ended round to pendingDrawRound
├── Create new activeRound
└── Initialize batch processing state

Phase 2: processDrawBatch() [repeat until complete]
├── Process N receivers per call
├── Finalize TWAB for each user
└── Build cumulative weight array

Phase 3: requestDrawRandomness()
├── Materialize pending yield
├── Request randomness from Flow
└── Create PrizeDrawReceipt

Phase 4: completeDraw()
├── Fulfill randomness
├── Select winners (weighted random)
├── Distribute prizes (auto-compound)
└── Cleanup pending state
```

---

## Entitlements & Access Control

```cadence
entitlement ConfigOps    // Non-destructive config (intervals, bonuses, rewards)
entitlement CriticalOps  // Impactful changes (strategies, emergency, draws)
entitlement OwnerOnly    // Highly sensitive (treasury recipient) - NEVER delegate
entitlement PositionOps  // User operations (deposit, withdraw, claim)
```

### Admin Capability Hierarchy

- **Full Admin**: ConfigOps + CriticalOps (for operators)
- **Config Only**: ConfigOps (for monitoring services)
- **Owner Only**: Never issue as capability (storage access only)

---

## Emergency Mode States

```cadence
enum PoolEmergencyState {
    Normal        // All operations allowed
    Paused        // No operations allowed
    EmergencyMode // Withdrawals only
    PartialMode   // Limited deposits, no draws
}
```

Auto-triggers based on:
- Low yield source health score
- Consecutive withdrawal failures
- Manual admin intervention

---

## User Positions

### PoolPositionCollection (Lottery-Eligible)
- Earns savings yield
- Participates in lottery draws
- TWAB tracked for fair lottery odds

### SponsorPositionCollection (Lottery-Ineligible)
- Earns savings yield
- Cannot win lottery prizes
- Useful for protocol treasuries, foundations

---

## Key Files for Understanding the System

| File | Purpose |
|------|---------|
| `cadence/contracts/PrizeSavings.cdc` | Main contract - all core logic |
| `docs/ACCOUNTING.md` | Deep dive into shares model |
| `docs/TWAB.md` | Time-weighted balance mechanics |
| `cadence/tests/*_test.cdc` | Test cases reveal expected behavior |

---

## Common Operations

### Creating a Pool (Admin)

```cadence
admin.createPool(
    config: PoolConfig(
        assetType: Type<@FlowToken.Vault>(),
        yieldConnector: connector,
        minimumDeposit: 1.0,
        drawIntervalSeconds: 604800.0,  // 7 days
        distributionStrategy: FixedPercentageStrategy(
            savings: 0.4, lottery: 0.4, treasury: 0.2
        ),
        prizeDistribution: SingleWinnerPrize(nftIDs: []),
        winnerTrackerCap: nil
    ),
    emergencyConfig: nil  // Uses defaults
)
```

### User Deposit

```cadence
// One-time setup
let collection <- PrizeSavings.createPoolPositionCollection()
account.storage.save(<- collection, to: PrizeSavings.PoolPositionCollectionStoragePath)

// Deposit
let collectionRef = account.storage.borrow<auth(PositionOps) &PoolPositionCollection>(
    from: PrizeSavings.PoolPositionCollectionStoragePath
)!
collectionRef.deposit(poolID: 0, from: <- vault)
```

### Running a Draw

```cadence
// Phase 1: Start (instant)
admin.startPoolDraw(poolID: 0)

// Phase 2: Batch process (repeat until complete)
while !pool.isBatchComplete() {
    admin.processPoolDrawBatch(poolID: 0, limit: 100)
}

// Phase 3: Request randomness
admin.requestPoolDrawRandomness(poolID: 0)

// Phase 4: Complete (next block)
admin.completePoolDraw(poolID: 0)
```

---

## Important Constants

```cadence
VIRTUAL_SHARES = 0.0001         // Inflation attack protection
VIRTUAL_ASSETS = 0.0001         // Inflation attack protection
MINIMUM_DISTRIBUTION_THRESHOLD = 0.000001  // Prevents precision loss
```

---

## Events for Monitoring

Key events to watch:

```cadence
// Deposits/Withdrawals
Deposited(poolID, receiverID, amount)
Withdrawn(poolID, receiverID, requestedAmount, actualAmount)

// Yield Processing
RewardsProcessed(poolID, totalAmount, savingsAmount, lotteryAmount)
SavingsYieldAccrued(poolID, amount)
DeficitApplied(poolID, totalDeficit, absorbedByLottery, absorbedBySavings)

// Lottery
PrizeDrawCommitted(poolID, prizeAmount, commitBlock)
PrizesAwarded(poolID, winners, amounts, round)
NewRoundStarted(poolID, roundID, startTime, duration)

// Emergency
PoolEmergencyEnabled(poolID, reason, adminUUID, timestamp)
EmergencyModeAutoTriggered(poolID, reason, healthScore, timestamp)
```

---

## Testing

**IMPORTANT**: The full test suite (`make test`) runs all 28 test files and can take several minutes. For faster iteration, run targeted test files directly:

```bash
# Run a specific test file (recommended for fast iteration)
flow test cadence/tests/RoundTWAB_test.cdc
flow test cadence/tests/BatchDraw_test.cdc
flow test cadence/tests/PoolDraws_test.cdc

# Run fast tests (all 28 files - can be slow)
make test

# Run all tests including long-running stress tests
make test-all

# Run with coverage
make test-cover
```

### Key Test Files by Area

| Area | Test File |
|------|-----------|
| TWAB calculations | `RoundTWAB_test.cdc`, `NormalizedTWABEdgeCases_test.cdc`, `TWABOverflow_test.cdc` |
| Draw processing | `BatchDraw_test.cdc`, `PoolDraws_test.cdc`, `DrawPhaseInteraction_test.cdc` |
| Deposits/Withdrawals | `PoolDepositsWithdraws_test.cdc`, `PoolPositionCollection_test.cdc` |
| Gap periods | `GapPeriod_test.cdc`, `RoundEdgeCases_test.cdc` |
| Emergency mode | `EmergencyConfig_test.cdc` |
| Share accounting | `SharePricePrecision_test.cdc`, `DeficitHandling_test.cdc` |

---

## Benchmarking

The `benchmark/` directory contains tools for measuring computation units (CUs):

```bash
# Run benchmark with specific user count
python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500

# Run with profiling (saves pprof files)
python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000 --profile

# Skip emulator setup (if already running)
python3 benchmark/benchmark_draw_computation.py --users 500 --skip-setup
```

### Current Performance Baseline

| Users | processDrawBatch CUs | CU/User |
|------:|--------------------:|--------:|
| 500   | ~1,635              | ~3.27   |
| 1,000 | ~3,250              | ~3.25   |
| 3,000 | ~9,768              | ~3.26   |

**Maximum batch size**: ~3,075 users per transaction (within 9,999 CU limit)

### Optimization Learnings

**Attempted optimization**: Consolidating 3 TWAB dictionaries into 1 struct to reduce lookups.

**Result**: This approach was ~4% SLOWER due to:
- Struct creation overhead on writes
- Optional chaining overhead
- Cadence's dictionary implementation already caches same-key lookups efficiently

**Lesson**: Cadence's dictionary access is well-optimized; consolidating into structs adds overhead rather than reducing it.

---

## External Dependencies

Key imports in `PrizeSavings.cdc`:

```cadence
import "FungibleToken"      // Token standard
import "NonFungibleToken"   // NFT support
import "RandomConsumer"     // Flow protocol randomness
import "DeFiActions"        // Yield source connectors
import "DeFiActionsUtils"   // DeFi utilities
import "PrizeWinnerTracker" // Winner history tracking
import "Xorshift128plus"    // PRNG for multi-winner selection
```

---

## Architecture Decisions & Rationale

1. **Why ERC4626 shares?** O(1) yield distribution without iterating users
2. **Why normalized TWAB?** Prevents whale manipulation, rewards commitment
3. **Why virtual offset?** Prevents first-depositor inflation attacks
4. **Why batch processing?** Supports unlimited users without gas limits
5. **Why resource-based positions?** Clean ownership semantics, composability
6. **Why separate sponsor positions?** Allows liquidity without competing in lottery

---

## Common Gotchas

1. **Round duration is immutable** once a round starts - use `updatePoolDrawIntervalForFutureRounds()`
2. **TWAB is normalized** - values represent "average shares", not share-seconds
3. **Virtual offset causes tiny dust** - accounted for in treasury
4. **Treasury recipient requires OwnerOnly** - cannot be delegated via capability
5. **Withdrawal may return empty vault** if yield source has liquidity issues
6. **Unregistration blocked during draws** to prevent index corruption

---

## When Modifying Code

1. **Maintain invariants**: `allocatedFunds == yield source balance` after sync
2. **Update TWAB on share changes**: Call `recordShareChange()` before and after
3. **Handle gap periods**: Users depositing after round ends get zero lottery weight
4. **Test deficit scenarios**: Ensure losses are socialized fairly
5. **Check emergency transitions**: All state transitions should be valid
