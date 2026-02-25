# FlowPrizeVault Command Reference

Copy-paste Flow CLI commands for all essential operations.

## Quick Reference

| Operation | Transaction | Parameters |
|-----------|-------------|------------|
| Deploy contracts | `flow project deploy` | network |
| Setup yield vault | `setup_test_yield_vault.cdc` | - |
| **Pool Creation** | | |
| Single winner pool | `create_pool_single_winner.cdc` | config + yieldVaultPath |
| Multi-winner (%) pool | `create_pool_percentage_split.cdc` | config + prizeSplits + yieldVaultPath |
| Multi-tier pool | `create_pool_fixed_tiers.cdc` | config + tiers + yieldVaultPath |
| **Pool Updates** | | |
| Change to % split | `update_prize_distribution_percentage.cdc` | poolID, prizeSplits |
| Change to single winner | `update_prize_distribution_single.cdc` | poolID |
| Change to fixed tiers | `update_prize_distribution_tiers.cdc` | poolID, tiers |
| **User Operations** | | |
| Setup collection | `setup_collection.cdc` | - |
| Deposit | `deposit.cdc` | poolID, amount |
| Withdraw | `withdraw.cdc` | poolID, amount |
| **Draw Cycle** | | |
| Add yield | `add_yield_to_pool.cdc` | amount |
| Fund prize pool directly | `test/fund_prize_pool.cdc` | poolID, amount |
| Smart draw | `start_draw_full.cdc` | poolID |
| Complete draw | `complete_draw.cdc` | poolID |
| Start next round | `start_next_round.cdc` | poolID |
| **Queries** | | |
| List pools | `get_all_pools.cdc` | - |
| Pool stats | `get_pool_stats.cdc` | poolID |
| Draw status | `get_draw_status.cdc` | poolID |
| User shares | `get_user_shares.cdc` | address, poolID |
| Yield status (real-time) | `get_yield_status.cdc` | poolID |

---

## Environment Setup

### Network Configuration

All commands use `--network` and `--signer` flags:

```bash
# Emulator (local development)
--network=emulator --signer=emulator-account

# Testnet
--network=testnet --signer=testnet-account

# Mainnet
--network=mainnet --signer=mainnet-account
```

Account names come from your `flow.json` configuration.

---

## 1. Initial Setup

### 1.1 Deploy Contracts

Deploy all contracts defined in `flow.json`:

```bash
flow project deploy --network=emulator
```

### 1.2 Setup Yield Vault

Creates a vault that serves as the yield source. The pool deposits user funds here and withdraws yield.

**For Emulator/Testnet (MockYieldConnector):**

```bash
flow transactions send cadence/transactions/prize-linked-accounts/setup_test_yield_vault.cdc \
  --network=testnet \
  --signer=testnet-account3
```

This creates `/storage/testYieldVault`. You manually add "yield" to this vault to simulate interest.

**For Production:**

Production requires a real yield connector that integrates with a DeFi protocol (e.g., Increment, lending pools). You'll need to:
1. Deploy a yield connector contract implementing `DeFiActions.Sink` and `DeFiActions.Source`
2. Create pool creation transactions that use that connector instead of MockYieldConnector

---

## 2. Pool Creation

**PREREQUISITE:** Run `setup_test_yield_vault.cdc` first to create the yield vault before creating any pools.

Three prize distribution types are available. All use the same yield distribution strategy (configurable % split between savings, lottery, and treasury).

### Common Parameters (all pool types)

| Parameter | Name | Type | Description |
|-----------|------|------|-------------|
| 1 | minimumDeposit | UFix64 | Minimum FLOW to deposit |
| 2 | drawIntervalSeconds | UFix64 | Seconds between draws |
| 3 | rewardsPercent | UFix64 | % of yield to savings (0.7 = 70%) |
| 4 | prizePercent | UFix64 | % of yield to lottery (0.2 = 20%) |
| 5 | protocolFeePercent | UFix64 | % of yield to treasury (0.1 = 10%) |

**Note:** rewardsPercent + prizePercent + protocolFeePercent must equal 1.0

### 2.1 Single Winner Pool

One winner takes the entire prize pool each draw.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/create_pool_single_winner.cdc \
  10.0 \
  60.0 \
  0.5 \
  0.4 \
  0.1 \
  "testYieldVault" \
  --network=testnet \
  --signer=testnet-account3
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1-5 | (common) | | See above |
| 6 | yieldVaultPath | String | Storage path identifier (e.g., "testYieldVault") |

### 2.2 Percentage Split Pool

Multiple winners split the prize by percentage. Example: 50%/30%/20% split for 3 winners.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/create_pool_percentage_split.cdc \
  10.0 \
  86400.0 \
  0.5 \
  0.4 \
  0.1 \
  '[0.5, 0.3, 0.2]' \
  "testYieldVault" \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1-5 | (common) | | See above |
| 6 | prizeSplits | [UFix64] | Array of percentages (must sum to 1.0) |
| 7 | yieldVaultPath | String | Storage path identifier |

**Prize Split Examples:**
```bash
# 2 winners: 70%/30%
'[0.7, 0.3]'

# 3 winners: 50%/30%/20%
'[0.5, 0.3, 0.2]'

# 5 winners: 40%/25%/15%/12%/8%
'[0.4, 0.25, 0.15, 0.12, 0.08]'
```

### 2.3 Fixed Tiers Pool

Multiple prize tiers with fixed amounts and winner counts. Good for "Grand Prize / Runner Up / Consolation" structures.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/create_pool_fixed_tiers.cdc \
  10.0 \
  86400.0 \
  0.5 \
  0.4 \
  0.1 \
  '[100.0, 25.0, 5.0]' \
  '[1, 2, 5]' \
  '["Grand Prize", "Runner Up", "Consolation"]' \
  "testYieldVault" \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1-5 | (common) | | See above |
| 6 | tierAmounts | [UFix64] | Prize amount for each tier |
| 7 | tierCounts | [Int] | Number of winners per tier |
| 8 | tierNames | [String] | Display name for each tier |
| 9 | yieldVaultPath | String | Storage path identifier |

**Tier Examples:**

```bash
# Simple: 1 grand prize, 3 runners up
'[50.0, 10.0]' '[1, 3]' '["Grand Prize", "Runner Up"]'

# Complex: jackpot + medium + many small prizes
'[1000.0, 100.0, 10.0, 1.0]' '[1, 5, 20, 100]' '["Jackpot", "Gold", "Silver", "Bronze"]'
```

**Note:** Fixed tiers pay out the specified amounts. If the prize pool has less than the total tier amounts, prizes are reduced proportionally.

### 2.4 Legacy: Simple Test Pool

For quick testing with hardcoded MockYieldConnector path:

```bash
flow transactions send cadence/transactions/prize-linked-accounts/create_test_pool.cdc \
  1.0 \
  10.0 \
  0.7 \
  0.2 \
  0.1 \
  --network=emulator \
  --signer=emulator-account
```

### 2.5 Updating Prize Distribution

Prize distribution can be changed at any time. The new distribution applies to the next draw.

**Change to Percentage Split (multiple winners):**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/update_prize_distribution_percentage.cdc \
  0 \
  '[0.6, 0.4]' \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID to update |
| 2 | prizeSplits | [UFix64] | Array of percentages (must sum to 1.0) |

**Examples:**
```bash
# 2 winners: 60%/40%
'[0.6, 0.4]'

# 3 winners: 50%/30%/20%
'[0.5, 0.3, 0.2]'

# 2 winners: 70%/30%
'[0.7, 0.3]'
```

**Change to Single Winner:**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/update_prize_distribution_single.cdc \
  0 \
  --network=emulator \
  --signer=emulator-account
```

**Change to Fixed Tiers:**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/update_prize_distribution_tiers.cdc \
  0 \
  '[100.0, 25.0]' \
  '[1, 2]' \
  '["Grand Prize", "Runner Up"]' \
  --network=emulator \
  --signer=emulator-account
```

**Custom Distributions:** For prize distributions beyond the built-in types, deploy a contract implementing `PrizeLinkedAccounts.PrizeDistribution`, then write a transaction that uses it.

---

## 3. User Operations

### 3.1 Setup User Collection

Creates a `PoolPositionCollection` for the user. Run once per account before depositing.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/setup_collection.cdc \
  --network=emulator \
  --signer=emulator-account
```

### 3.2 Deposit

Deposits FLOW tokens into a pool. Auto-registers the user on first deposit.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/deposit.cdc \
  0 \
  100.0 \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID (usually 0 for first pool) |
| 2 | amount | UFix64 | Amount of FLOW to deposit |

### 3.3 Withdraw

Withdraws tokens from a pool (principal + any accrued rewards).

```bash
flow transactions send cadence/transactions/prize-linked-accounts/withdraw.cdc \
  0 \
  50.0 \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | amount | UFix64 | Amount of FLOW to withdraw |

### 3.4 Check User Balance

Query a user's shares and balance in a pool.

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_user_shares.cdc \
  0x01cf0e2f2f715450 \
  0 \
  --network=emulator
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | address | Address | User's account address |
| 2 | poolID | UInt64 | Pool ID |

**Returns:** `UserSharesInfo` with:
- `shares` - Current share balance
- `shareValue` - Value of shares in FLOW
- `timeWeightedStake` - TWAB weight for current round
- `totalEarnedPrizes` - Total prizes won
- `totalBalance` - Total balance including prizes
- `bonusWeight` - Any bonus weight assigned

---

## 4. Draw Cycle

The draw process has 4 phases:
1. **startDraw** - End round, materialize yield, request randomness
2. **processDrawBatch** - Finalize TWAB weights for all users
3. **requestDrawRandomness** - (happens in startDraw)
4. **completeDraw** - Select winners, distribute prizes

### 4.1 Add Yield (Simulate)

Adds FLOW to the yield vault to simulate yield generation. This will be distributed according to the pool's distribution strategy on the next draw.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/add_yield_to_pool.cdc \
  50.0 \
  --network=testnet \
  --signer=testnet-account3
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | amount | UFix64 | Amount of FLOW to add as yield |

**Note:** This only works with MockYieldConnector. In production, yield comes from the real DeFi protocol.

### 4.2 Fund Prize Pool Directly (Admin)

Bypasses the yield distribution split and deposits FLOW directly into the prize pool. Useful for sponsorships, promotional prize seeding, or testing draws with a guaranteed prize amount. Requires the Admin resource (`CriticalOps` entitlement).

```bash
flow transactions send cadence/transactions/test/fund_prize_pool.cdc \
  0 \
  100.0 \
  --network=testnet \
  --signer=testnet-account3
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID to fund |
| 2 | amount | UFix64 | Amount of FLOW to deposit into the prize pool |

**Note:** The funds come from the signer's own FlowToken vault and go directly to the pool's prize allocation — they are **not** split through the yield distribution strategy. The destination is hardcoded to `PoolFundingDestination.Prize`. To fund rewards (share price increase) instead, modify the transaction to use `PoolFundingDestination.Rewards`.

### 4.3 Smart Draw (Recommended)

Intelligently advances the draw process based on current pool state. Call repeatedly until complete.

```bash
flow transactions send cadence/transactions/prize-linked-accounts/start_draw_full.cdc \
  0 \
  --network=emulator \
  --signer=emulator-account
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

**Behavior by pool state:**
| Pool State | Action Taken |
|------------|--------------|
| `ROUND_ACTIVE` | No action (round hasn't ended) |
| `AWAITING_DRAW` | Starts draw + processes all batches |
| `DRAW_PROCESSING` | Continues batch processing |
| `Ready for completion` | Completes draw + auto-starts next round |
| `INTERMISSION` | Starts next round |

**Typical usage (2 calls needed):**
```bash
# Call 1: Starts draw + processes batches
flow transactions send cadence/transactions/prize-linked-accounts/start_draw_full.cdc 0 \
  --network=emulator --signer=emulator-account

# Call 2 (next block): Completes draw + starts next round
flow transactions send cadence/transactions/prize-linked-accounts/start_draw_full.cdc 0 \
  --network=emulator --signer=emulator-account
```

**Note:** Two calls are needed because randomness must be requested in one block and fulfilled in a subsequent block.

### 4.4 Manual Draw Controls

For fine-grained control, use these individual transactions:

**Start Draw (Phase 1 only):**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/start_draw.cdc \
  0 \
  --network=emulator \
  --signer=emulator-account
```

**Complete Draw (Phase 3):**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/complete_draw.cdc \
  0 \
  --network=emulator \
  --signer=emulator-account
```

**Start Next Round:**
```bash
flow transactions send cadence/transactions/prize-linked-accounts/start_next_round.cdc \
  0 \
  --network=emulator \
  --signer=emulator-account
```

**Parameters (all manual commands):**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

---

## 5. Query Commands

### 5.1 List All Pools

Returns an array of all pool IDs.

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_all_pools.cdc \
  --network=emulator
```

### 5.2 Pool Stats

Comprehensive pool statistics.

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc \
  0 \
  --network=testnet
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

**Returns:** `PoolStats` with:
- `sharePrice` - Current share price
- `totalShares` / `totalAssets` - Pool totals
- `prizePoolBalance` - Available prize amount
- `allocatedRewards` - Rewards distributed to share price
- `registeredUserCount` - Number of depositors
- `canDrawNow` / `isDrawInProgress` - Draw state
- `currentRoundID` / `roundElapsedTime` - Round info
- `isInIntermission` - Whether between rounds
- `emergencyState` - 0=Normal, 1=Paused, 2=Emergency, 3=Partial

### 5.3 Draw Status

Detailed draw state machine status.

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc \
  0 \
  --network=emulator
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

**Returns:** `DrawStatus` with:
- `poolState` - One of: `ROUND_ACTIVE`, `AWAITING_DRAW`, `DRAW_PROCESSING`, `INTERMISSION`
- `canDrawNow` - Whether `startDraw` can be called
- `isReadyForCompletion` - Whether `completeDraw` can be called
- `secondsUntilNextDraw` - Time remaining in round
- `prizePoolBalance` / `allocatedPrizeYield` - Prize amounts
- `batchProgress` - Batch processing status (if in progress)

### 5.4 Yield Status (Real-time)

Live yield source data compared to cached pool accounting. Use this to see pending yield before it's synced.

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_yield_status.cdc \
  0 \
  --network=emulator
```

**Parameters:**
| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

**Returns:** `YieldStatus` with:
- `yieldSourceBalance` - Actual balance in yield source (real-time)
- `totalAllocatedFunds` - Sum of cached allocations
- `userPoolBalance` / `allocatedPrizeYield` / `allocatedProtocolFee` - Breakdown
- `pendingYield` - Unsynced yield (positive = gains, negative = deficit)
- `needsSync` - Whether pool needs to sync with yield source
- `availableYieldRewards` - Yield available for distribution

**Example output:**
```
yieldSourceBalance: 110.0      # Actual in yield source
totalAllocatedFunds: 100.0     # Cached total
pendingYield: 10.0             # 10 FLOW yield pending sync
needsSync: true                # Will sync on next deposit/withdraw
```

---

## Parameter Reference

### Types

| Type | Format | Examples |
|------|--------|----------|
| UFix64 | Decimal with up to 8 places | `100.0`, `0.00000001` |
| UInt64 | Non-negative integer | `0`, `1`, `42` |
| Address | Hex with 0x prefix | `0x01cf0e2f2f715450` |
| Int | Integer (can be negative) | `100`, `-1` |
| String | Quoted text | `"testYieldVault"` |
| [Type] | JSON array | `'[0.5, 0.3, 0.2]'` |

### Common Values

| Parameter | Testing | Production |
|-----------|---------|------------|
| minimumDeposit | `1.0` | `10.0` - `100.0` |
| drawIntervalSeconds | `10.0` | `86400.0` (daily) or `604800.0` (weekly) |
| yieldVaultPath | `"testYieldVault"` | (depends on connector) |

### Pool States

| State | Description | Next Action |
|-------|-------------|-------------|
| `ROUND_ACTIVE` | Round in progress | Wait for round to end |
| `AWAITING_DRAW` | Round ended | Call `start_draw_full` |
| `DRAW_PROCESSING` | Draw in progress | Call `complete_draw` |
| `INTERMISSION` | Between rounds | Call `start_next_round` |

### Prize Distribution Comparison

| Type | Winners | Prize Calculation | Best For |
|------|---------|-------------------|----------|
| SingleWinner | 1 | 100% of prize pool | Maximum excitement, simple |
| PercentageSplit | N | % of prize pool | Multiple winners, scales with yield |
| FixedAmountTiers | N per tier | Fixed amounts | Predictable prizes, lottery-style |

---

## Complete Workflow Example

Full end-to-end test on emulator with single winner pool:

```bash
# 1. Start emulator (in separate terminal)
flow emulator

# 2. Deploy contracts
flow project deploy --network=emulator

# 3. Setup yield vault (admin)
flow transactions send cadence/transactions/prize-linked-accounts/setup_test_yield_vault.cdc \
  --network=emulator --signer=emulator-account

# 4. Create single winner pool (daily draws)
flow transactions send cadence/transactions/prize-linked-accounts/create_pool_single_winner.cdc \
  1.0 10.0 0.5 0.4 0.1 "testYieldVault" \
  --network=emulator --signer=emulator-account

# 5. Setup user collection
flow transactions send cadence/transactions/prize-linked-accounts/setup_collection.cdc \
  --network=emulator --signer=emulator-account

# 6. Deposit 100 FLOW
flow transactions send cadence/transactions/prize-linked-accounts/deposit.cdc \
  0 100.0 \
  --network=emulator --signer=emulator-account

# 7. Add yield (simulates interest earned)
flow transactions send cadence/transactions/prize-linked-accounts/add_yield_to_pool.cdc \
  10.0 \
  --network=emulator --signer=emulator-account

# 8. Wait for round to end (10+ seconds)
sleep 12

# 9. Check draw status
flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc 0 \
  --network=emulator

# 10. Start draw (starts + processes batches)
flow transactions send cadence/transactions/prize-linked-accounts/start_draw_full.cdc \
  0 \
  --network=emulator --signer=emulator-account

# 11. Complete draw (completes + starts next round)
flow transactions send cadence/transactions/prize-linked-accounts/start_draw_full.cdc \
  0 \
  --network=emulator --signer=emulator-account

# 12. Check pool stats (see prize distribution)
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 \
  --network=emulator

# 13. Check user balance
flow scripts execute cadence/scripts/prize-linked-accounts/get_user_shares.cdc \
  0xf8d6e0586b0a20c7 0 \
  --network=emulator
```

---

## Yield Connector Notes

### Current: MockYieldConnector

The `MockYieldConnector` is for testing only. It wraps a simple FlowToken vault:
- Deposits go directly to the vault
- Withdrawals come from the vault
- You manually add "yield" using `add_yield_to_pool.cdc`

### Production: Real Yield Connector

For production, you need a yield connector that:
1. Implements `DeFiActions.Sink` (for deposits)
2. Implements `DeFiActions.Source` (for withdrawals)
3. Connects to a real yield-generating protocol

Example architecture:
```
User Deposits → Pool → YieldConnector → DeFi Protocol (Increment, etc.)
                                      ↓
                              Yield accrues automatically
                                      ↓
Draw → Pool ← YieldConnector ← Withdraws yield + principal
```

To create a production pool:
1. Deploy your yield connector contract
2. Create a new pool creation transaction that imports your connector
3. Configure capabilities to your yield source
