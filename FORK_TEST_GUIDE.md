# Fork Test Guide: EVM Bridge Decimal Precision Fix

Test the updated `FlowYieldVaultsConnectorV2` against real mainnet state using the emulator fork.

## Prerequisites

- Flow CLI installed (`flow version` should work)
- You're on the `ben/fix-precision` branch
- `mainnet-deployer.pkey` exists in the project root

## What We're Testing

The withdrawal path through `FlowYieldVaultsConnectorV2` was failing because the EVM bridge truncates to 6 decimals while Cadence uses 8. The fix adds `truncateTo6DecimalPrecision()` in the connector. We need to verify this doesn't cause accounting drift, phantom yield, dust accumulation, or invariant violations.

**Core risk:** Every connector operation can lose up to 0.00000099 UFix64 (8→6 decimal truncation). Safety mechanisms that should absorb this:
- `dustThreshold` (minimumDeposit/10) in `ShareTracker.withdraw()`
- `MINIMUM_DISTRIBUTION_THRESHOLD` (0.000001) in `syncWithYieldSource()`
- `applyDeficit()` waterfall (protocol → prize → rewards)

**Key invariant at every step:** `|yieldSourceBalance - totalAllocatedFunds| < 0.000001`

---

## Setup

### Start the Emulator Fork

Open a **dedicated terminal** (runs in foreground):

```bash
flow emulator --fork mainnet --fork-height 142781958
```

Leave this running. All commands below go in a **second terminal**.

> **Note:** Restart the emulator between scenarios for clean state, or run scenarios sequentially (state accumulates).

### Helper: Query All State

Copy-paste this block before and after each operation to capture full state:

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
flow scripts execute cadence/scripts/fork-test/get_draw_status.cdc 0 --network mainnet-fork
```

---

## Scenario 1: Contract Update Sanity Check

**Goal:** Confirm the connector update alone doesn't change any pool state.

### Step 1a: Record pre-update state

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 1b: Deploy updated connector

```bash
flow project deploy --network mainnet-fork --update
```

Expected output:
```
Contract 'FlowYieldVaultsConnectorV2' deployed/updated on account 'a092c4aab33daeda'
```

### Step 1c: Record post-update state

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Verify

- All values identical before and after
- `needsSync` unchanged
- No phantom yield or deficit created
- `pendingYield` unchanged

---

## Scenario 2: Partial Withdrawal

**Goal:** Verify truncation is handled correctly when user keeps a position.

### Step 2a: Record pre-state

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 2b: Deploy connector (if not already done)

```bash
flow project deploy --network mainnet-fork --update
```

### Step 2c: Withdraw 1.0 pyUSD (partial)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 1.0 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

### Step 2d: Record post-state

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Verify

- User shares decreased proportionally
- User still registered (`is_registered` returns `true`)
- `|yieldSourceBalance - totalAllocatedFunds|` < 0.000001
- `needsSync` is `false` (or if `true`, mismatch < threshold)
- Share price stable (compare pre/post `sharePrice`)

---

## Scenario 3: Sequential Partial Withdrawals (Dust Accumulation)

**Goal:** Verify truncation dust doesn't accumulate dangerously across multiple operations.

### Step 3a: Deploy connector

```bash
flow project deploy --network mainnet-fork --update
```

### Step 3b: Record initial state

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 3c: Withdraw #1 (0.10 pyUSD)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 0.10 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 3d: Withdraw #2 (0.10 pyUSD)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 0.10 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 3e: Withdraw #3 (0.10 pyUSD)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 0.10 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 3f: Withdraw remaining balance

Check remaining balance first:

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

Then withdraw the returned value (replace `REMAINING` with the number from above):

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 REMAINING --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

### Verify

- Accounting mismatch stays below 0.000001 after each withdrawal (or self-corrects via sync)
- Final withdrawal triggers `burnAllShares` → user unregistered (`is_registered` returns `false`)
- No cascading deficit (check `pendingYield` stays near 0 or slightly negative)

---

## Scenario 4: Full Withdrawal with Deep Accounting Verification

**Goal:** Extend the initial test with comprehensive state checks.

### Step 4a: Deploy connector & record pre-state

```bash
flow project deploy --network mainnet-fork --update
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

Note down: user shares, shareValue, pool totalAssets, totalShares, userPoolBalance, yieldSourceBalance, totalAllocatedFunds.

### Step 4b: Full withdrawal

Replace `FULL_BALANCE` with the value from `get_user_balance` above:

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 FULL_BALANCE --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

### Step 4c: Record post-state

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Verify

- User: 0 shares, unregistered (`is_registered` returns `false`)
- Pool: `totalAssets` decreased by `actualWithdrawn`, `totalShares` decreased by user's shares
- `userPoolBalance` decreased by `actualWithdrawn`
- `|yieldSourceBalance - totalAllocatedFunds|` < 0.000001
- Share price unchanged for remaining users (if any)

---

## Scenario 5: Deposit → Withdraw Round-Trip

**Goal:** Verify pool functions normally after a truncated withdrawal + re-deposit cycle.

### Step 5a: Deploy connector & full withdraw

```bash
flow project deploy --network mainnet-fork --update
```

Get user balance:

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

Full withdraw (replace `FULL_BALANCE` with value from above):

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 FULL_BALANCE --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

Confirm unregistered:

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

### Step 5b: Re-deposit pyUSD back into pool

Use the withdrawn amount or slightly less. The third argument `10000` is maxSlippageBps (no protection — fine for fork testing):

```bash
flow transactions send cadence/transactions/fork-test/deposit_pyusd.cdc 0 AMOUNT 10000 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

Check re-registration:

```bash
flow scripts execute cadence/scripts/fork-test/get_user_shares.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 5c: Withdraw again

Get new balance:

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

Withdraw (replace `NEW_BALANCE` with value from above):

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 NEW_BALANCE --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

Verify final state:

```bash
flow scripts execute cadence/scripts/fork-test/is_registered.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Verify

- User re-registered after deposit (`is_registered` returns `true`)
- Shares minted at correct share price
- Second withdrawal succeeds cleanly
- User unregistered after final withdrawal
- Accounting invariants hold throughout: `|yieldSourceBalance - totalAllocatedFunds|` < 0.000001

---

## Scenario 6: Draw Cycle Through Truncated Connector

**Goal:** Verify protocol fee withdrawal and prize distribution work with truncation.

> **Note:** This depends on pool state at fork height. If the draw is not available, skip this scenario.

### Step 6a: Deploy connector & check draw eligibility

```bash
flow project deploy --network mainnet-fork --update
```

```bash
flow scripts execute cadence/scripts/fork-test/get_draw_status.cdc 0 --network mainnet-fork
```

Check the output:
- If `canDrawNow: true` or `isAwaitingDraw: true` → proceed to 6b
- If `isRoundActive: true` and `isRoundEnded: false` → round hasn't ended, **skip this scenario**
- If `isDrawProcessing: true` → draw already in progress, skip to 6c

### Step 6b: Start draw + process batches

```bash
flow transactions send cadence/transactions/fork-test/start_draw_full.cdc 0 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_draw_status.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Step 6c: Complete draw (must be in a different block)

The emulator auto-advances blocks, so just send the transaction again:

```bash
flow transactions send cadence/transactions/fork-test/start_draw_full.cdc 0 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_draw_status.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

### Verify

- `startDraw()` protocol fee withdrawal doesn't panic
- Prize distribution doesn't panic
- `allocatedProtocolFee` residual ≤ 0.00000099 (acceptable dust)
- `|yieldSourceBalance - totalAllocatedFunds|` < 0.000001
- Draw status transitions correctly through states

---

## Scenario 7: Boundary Amount Withdrawals

**Goal:** Test amounts at the 6-decimal precision boundary.

### Step 7a: Deploy connector

```bash
flow project deploy --network mainnet-fork --update
```

### Step 7b: Exact 6-decimal amount (no truncation needed)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 0.100000 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

### Step 7c: Minimum 6-decimal amount (exact boundary)

```bash
flow transactions send cadence/transactions/fork-test/withdraw_pyusd.cdc 0 0.000001 --network mainnet-fork --signer mainnet-deployer --gas-limit 9999
```

```bash
flow scripts execute cadence/scripts/fork-test/get_yield_status.cdc 0 --network mainnet-fork
```

```bash
flow scripts execute cadence/scripts/fork-test/get_user_balance.cdc 0xa092c4aab33daeda 0 --network mainnet-fork
```

### Verify

- All withdrawals succeed without panic
- Remaining balance is correct after each
- No accounting drift: `|yieldSourceBalance - totalAllocatedFunds|` < 0.000001

---

## Troubleshooting

### "import could not be resolved" on scripts/transactions

The `mainnet-fork` network does NOT inherit mainnet aliases automatically. You must explicitly add `"mainnet-fork"` aliases to every contract/dependency that your scripts, transactions, or contract updates import.

**Required `mainnet-fork` aliases in `contracts` section:**
- `DeFiActions` → `"mainnet-fork": "92195d814edf9cb0"`
- `DeFiActionsUtils` → `"mainnet-fork": "92195d814edf9cb0"`
- `FlowYieldVaultsConnectorV2` → `"mainnet-fork": "a092c4aab33daeda"`
- `PrizeLinkedAccounts` → `"mainnet-fork": "a092c4aab33daeda"`

**Required `mainnet-fork` aliases in `dependencies` section:**
- `FlowYieldVaults` → `"mainnet-fork": "b1d63873c3cc9f79"`
- `FlowYieldVaultsClosedBeta` → `"mainnet-fork": "b1d63873c3cc9f79"`
- `FungibleToken` → `"mainnet-fork": "f233dcee88fe0abe"`

**Also required in `networks` section:**
- `"mainnet-fork": "127.0.0.1:3569"`

### "No PoolPositionCollection found" on withdrawal

The deployer account doesn't have a PoolPositionCollection, meaning they haven't deposited into pool 0. Try querying other known user addresses instead.

### "update-contract" says contract doesn't exist

Verify the contract name matches exactly: `FlowYieldVaultsConnectorV2` (case-sensitive).

### Fork emulator crashes or hangs

Restart with a fresh fork — the emulator doesn't persist state between restarts, so you always get a clean mainnet snapshot.

### Withdrawal amount too small

If a withdrawal fails with a dust-related error, the amount may be below the pool's `minimumDeposit / 10` dust threshold. Check `minimumDeposit` in pool stats.

---

## Resetting

To start fresh, just kill the emulator (Ctrl+C) and restart it. Each restart forks from the same block height with clean mainnet state. No state carries over.

---

## Files for Fork Testing

| File | Purpose |
|------|---------|
| **Scripts** | |
| `cadence/scripts/fork-test/get_user_balance.cdc` | User's projected asset value |
| `cadence/scripts/fork-test/get_user_shares.cdc` | Detailed share breakdown |
| `cadence/scripts/fork-test/get_yield_status.cdc` | Yield/accounting invariant checks |
| `cadence/scripts/fork-test/is_registered.cdc` | Registration status |
| `cadence/scripts/fork-test/get_draw_status.cdc` | Draw state machine status |
| **Transactions** | |
| `cadence/transactions/fork-test/withdraw_pyusd.cdc` | Withdraw pyUSD from pool |
| `cadence/transactions/fork-test/deposit_pyusd.cdc` | Deposit pyUSD into pool |
| `cadence/transactions/fork-test/start_draw_full.cdc` | Smart draw state machine advancement |
| **Config** | |
| `flow.json` | mainnet-fork aliases for all contracts |
