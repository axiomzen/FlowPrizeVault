# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FlowPrizeVault** is a no-loss lottery / prize-linked savings protocol on Flow Blockchain using Cadence. Users deposit tokens to earn guaranteed savings interest while having chances to win lottery prizes funded by aggregated yield.

**Status**: Under security audit

## Commands

```bash
# Run fast tests (recommended for development)
make test

# Run a single test file (fastest iteration)
flow test cadence/tests/RoundTWAB_test.cdc

# Run all tests including long-running stress tests
make test-all

# Run only long-running stress tests
make test-long

# Run with coverage
make test-cover

# Suppress logs for cleaner output
flow test cadence/tests/*.cdc 2>&1 | grep -E "^(Test results:|- PASS|- FAIL)"
```

## Architecture

### Main Contract: `PrizeLinkedAccounts.cdc` (~5,800 lines)

```
PrizeLinkedAccounts (Contract)
├── Admin                    # Privileged operations (CriticalOps, ConfigOps entitlements)
├── Pool                     # Core deposit/withdrawal/yield/draw management
│   ├── ShareTracker         # ERC4626-style share accounting with virtual offset
│   ├── Round                # Per-round TWAB tracking (normalized)
│   └── config               # Yield connector, distribution strategy
├── PoolPositionCollection   # User's lottery-eligible position
└── SponsorPositionCollection # Lottery-ineligible position (for sponsors/treasuries)
```

### Three-Way Yield Split

```
Total Yield → DistributionStrategy.calculateDistribution()
           → Savings (share price ↑) + Lottery (prize pool) + Treasury (protocol fees)
```

### Draw Process (4 Phases)

1. `startDraw()` - Move ended round to pending, enter intermission
2. `processDrawBatch()` - Finalize TWAB for users (repeat until complete)
3. `requestDrawRandomness()` - Materialize yield, request Flow randomness
4. `completeDraw()` - Select winners, distribute prizes, cleanup

### TWAB (Time-Weighted Average Balance)

Prevents last-minute deposit manipulation. Weight accumulates from deposit time until `startDraw()` is called:

```
normalizedWeight = shares × (elapsed / actualRoundDuration)
```

User holding 100 shares for full 7-day round → weight = 100
User depositing 100 shares at day 6.5 → weight ≈ 7 (proportional)

### Entitlements

```cadence
entitlement ConfigOps    // Non-destructive config changes
entitlement CriticalOps  // Impactful: strategies, emergency, draws, migrations
entitlement OwnerOnly    // Treasury recipient - NEVER delegate as capability
entitlement PositionOps  // User: deposit, withdraw, claim
```

### Emergency States

```cadence
Normal        // All operations
Paused        // No operations
EmergencyMode // Withdrawals only
PartialMode   // Limited deposits, no draws
```

## Key Files

| File | Purpose |
|------|---------|
| `cadence/contracts/PrizeLinkedAccounts.cdc` | Main contract |
| `cadence/contracts/PrizeWinnerTracker.cdc` | Optional winner history |
| `docs/ACCOUNTING.md` | Shares model deep dive |
| `docs/TWAB.md` | Time-weighted balance mechanics |

## Test Files by Area

| Area | Test File |
|------|-----------|
| TWAB | `RoundTWAB_test.cdc`, `NormalizedTWABEdgeCases_test.cdc` |
| Draws | `BatchDraw_test.cdc`, `PoolDraws_test.cdc` |
| Gap periods | `GapPeriod_test.cdc`, `RoundEdgeCases_test.cdc` |
| Shares | `SharePricePrecision_test.cdc`, `DeficitHandling_test.cdc` |
| Emergency | `EmergencyConfig_test.cdc` |
| Multi-round | `MultiRoundSequence_test.cdc`, `Intermission_test.cdc` |

## Important Invariants

1. `allocatedRewards + allocatedPrizeYield + allocatedProtocolFee == yieldSourceBalance` (after sync)
2. `normalizedWeight <= shares` (TWAB safety cap)
3. `sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)` (virtual offset)

## Gotchas

1. **Round targetEndTime** is the MINIMUM time before `startDraw()` can be called, not when the round ends
2. **Actual round end** = when `startDraw()` is called (sets `actualEndTime`)
3. **TWAB is normalized** - values represent "average shares", not share-seconds
4. **Virtual offset** causes tiny dust amounts (~0.0001) - accounted for in treasury
5. **OwnerOnly entitlement** cannot be delegated via capability - storage access only
6. **Withdrawal may return less** than requested if yield source has liquidity issues
7. **Unregistration blocked during draws** to prevent index corruption (swap-and-pop)

## When Modifying Code

1. **Update TWAB on share changes**: Call `recordShareChange()` in deposit/withdraw
2. **Sync before operations**: Call `syncWithYieldSource()` before deposits/withdrawals
3. **Test deficit scenarios**: Ensure losses are socialized fairly (protocol → prize → rewards)
4. **Check emergency transitions**: All state transitions must be valid
5. **Preserve batch processing**: Don't corrupt indices during `processDrawBatch()`
6. **Respect draw phases**: The 4-phase draw (`startDraw` → `processDrawBatch` → `requestDrawRandomness` → `completeDraw`) must complete in order

## Deployment

| Network | Contract Address | Status |
|---------|------------------|--------|
| Emulator | `f8d6e0586b0a20c7` | Development |
| Testnet | `c24c9fd9b176ea87` | Testing |
| Mainnet | TBD | Pending Audit |
