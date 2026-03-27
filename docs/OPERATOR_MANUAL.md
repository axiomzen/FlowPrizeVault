# FlowPrizeVault — Operator Manual

Practical guide for operators running the PrizeLinkedAccounts contract on Flow.

---

## 1. Accounts & Entitlements

The contract uses four entitlements. Each operator account needs the right capability issued to it before it can perform its role.

| Entitlement | Who holds it | What it unlocks |
|-------------|-------------|-----------------|
| `OwnerOnly` | Deployer account only — **never delegated** | Set / clear protocol fee recipient |
| `CriticalOps` | Ops account | Create pools, start/complete draws, emergency on/off, withdraw unclaimed fees, update distribution strategy |
| `ConfigOps` | Ops or automation account | Start next round, update draw interval, update minimum deposit, update prize distribution, cleanup stale entries |
| `PositionOps` | Users | Deposit, withdraw, claim prizes |

> **`OwnerOnly` is never issued as a capability.** It can only be accessed by the deployer account via a direct storage borrow. Any transaction that needs it must be signed by the deployer.

Account names (`mainnet-deployer`, `mainnet-ops`, `mainnet-automation`) come from your `flow.json` configuration.

### Issuing capabilities (one-time setup)

From the deployer account, publish capabilities that operator accounts can claim. Issue the `FullAdmin` capability (CriticalOps + ConfigOps) for accounts that run the full draw cycle, or issue individual entitlements for more restricted roles.

**Issue full Admin capability** (for the ops account running `start_draw_full`):

```bash
flow transactions send cadence/transactions/operations/setup/issue_full_admin_capability.cdc \
  0xOPS_ACCOUNT \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | delegateAddress | Address | Account address to receive the capability |

**Issue CriticalOps-only capability** (for dedicated draw / emergency operator):

```bash
flow transactions send cadence/transactions/operations/setup/issue_critical_ops_capability.cdc \
  0xOPS_ACCOUNT \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | delegateAddress | Address | Account address to receive the capability |

**Issue ConfigOps-only capability** (for automation account running `start_next_round` and config changes):

```bash
flow transactions send cadence/transactions/operations/setup/issue_config_ops_capability.cdc \
  0xAUTOMATION_ACCOUNT \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | delegateAddress | Address | Account address to receive the capability |

From each operator account, claim the published capability:

**Claim full Admin capability** (needed for `start_draw_full.cdc`):

```bash
flow transactions send cadence/transactions/operations/setup/claim_full_admin_capability.cdc \
  0xDEPLOYER \
  --network=mainnet \
  --signer=mainnet-ops
```

**Claim CriticalOps-only capability**:

```bash
flow transactions send cadence/transactions/operations/setup/claim_critical_ops_capability.cdc \
  0xDEPLOYER \
  --network=mainnet \
  --signer=mainnet-ops
```

**Claim ConfigOps-only capability**:

```bash
flow transactions send cadence/transactions/operations/setup/claim_config_ops_capability.cdc \
  0xDEPLOYER \
  --network=mainnet \
  --signer=mainnet-automation
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | adminAddress | Address | Deployer account address that published the capability |

---

## 2. Querying Pool State

All scripts are read-only and require no signing.

### Get full pool statistics

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc \
  0 \
  --network=mainnet
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID (0 for first pool) |

Returns: TVL, share price, prize pool balance, round timing, yield split percentages, emergency state, registered user count.

### Get draw status

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc \
  0 \
  --network=mainnet
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

Returns `poolState` as one of: `ROUND_ACTIVE` | `AWAITING_DRAW` | `DRAW_PROCESSING` | `INTERMISSION`

Also returns `secondsUntilNextDraw`, `batchProgress` (cursor/total/percent), and `prizePoolBalance`.

### List all pools

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_all_pools.cdc \
  --network=mainnet
```

No parameters. Returns an array of all pool IDs.

### Check a user's balance and prize entries

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_user_shares.cdc \
  0xUSER_ADDRESS \
  0 \
  --network=mainnet
```

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_user_prize_entries.cdc \
  0xUSER_ADDRESS \
  0 \
  --network=mainnet
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | address | Address | User's account address |
| 2 | poolID | UInt64 | Pool ID |

### Check protocol fee accumulation

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_protocol_fee_stats.cdc \
  0 \
  --network=mainnet
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

### Check emergency state

```bash
flow scripts execute cadence/scripts/prize-linked-accounts/get_emergency_info.cdc \
  0 \
  --network=mainnet
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

---

## 3. Running the Draw Cycle

### Recommended: smart draw transaction

`start_draw_full.cdc` inspects the pool state and takes the appropriate action automatically. Call it repeatedly until the draw is complete. Requires the full Admin capability (CriticalOps + ConfigOps).

```bash
# Call in block N — starts draw and processes all TWAB batches
flow transactions send cadence/transactions/operations/draw/start_draw_full.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops

# Call in block N+1 or later — completes draw, distributes prizes, starts next round
flow transactions send cadence/transactions/operations/draw/start_draw_full.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

The two-block minimum is enforced by Flow's randomness commit-reveal protocol. Calling `completeDraw` in the same block as `startDraw` will panic.

### Manual step-by-step

Use these if you need fine-grained control or are recovering from a stuck draw.

**Phase 1 — Start draw** (requires `CriticalOps`):

```bash
flow transactions send cadence/transactions/operations/draw/start_draw.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

Pre-conditions checked automatically: round must have ended, no draw already in progress, `allocatedPrizeYield > 0`.

**Phase 2 — Process batches** (permissionless, repeat until complete):

```bash
# Check progress first
flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc \
  0 \
  --network=mainnet

# Submit batches — any account can sign; limit controls users processed per transaction
flow transactions send cadence/transactions/operations/draw/process_draw_batch.cdc \
  0 \
  500 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | limit | Int | Max users to process per call (500 is safe for most pools; lower if hitting compute limits) |

For pools with many users, lower `limit` if transactions approach computation limits.

**Phase 3 — Complete draw** (requires `CriticalOps`, must be a different block from Phase 1):

```bash
flow transactions send cadence/transactions/operations/draw/complete_draw.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

Winners are selected and prizes are auto-compounded into their share balances.

**Phase 4 — Start next round** (requires `ConfigOps`):

```bash
flow transactions send cadence/transactions/operations/draw/start_next_round.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

This exits intermission and begins a new TWAB round. During intermission, deposits and withdrawals still work but no TWAB is recorded.

---

## 4. Funding the Prize Pool

If no yield has accrued (zero APY period, new pool, yield source paused), `startDraw` will revert because `allocatedPrizeYield == 0`. Seed the prize pool directly to unblock:

```bash
flow transactions send cadence/transactions/operations/config/fund_prize_pool.cdc \
  0 \
  100.0 \
  "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault" \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | amount | UFix64 | Amount of tokens to add to the prize pool |
| 3 | vaultIdentifier | String | Storage path identifier for the signer's token vault — `"flowTokenVault"` for FLOW, `"EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault"` for pyUSD |

This calls `fundPoolDirect(destination: .Prize)` and requires `CriticalOps`. The funds count as prize yield for the next draw without affecting user share balances.

---

## 5. Protocol Fee Management

### Set fee recipient (deployer only)

Protocol fees are automatically forwarded on each sync once a recipient is set:

```bash
flow transactions send cadence/transactions/operations/fees/set_protocol_fee_recipient.cdc \
  0 \
  0xTREASURY \
  /public/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | recipientAddress | Address | Treasury account address |
| 3 | receiverPath | PublicPath | Public path of the recipient's `FungibleToken.Receiver` capability — e.g. `/public/flowTokenReceiver` for FLOW, `/public/EVMVMBridgedToken_...Receiver` for pyUSD |

The recipient must have a valid `FungibleToken.Receiver` capability at the specified public path.

### Clear fee recipient

Stops auto-forwarding. Fees accumulate in the unclaimed vault:

```bash
flow transactions send cadence/transactions/operations/fees/clear_protocol_fee_recipient.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

### Withdraw unclaimed fees (requires `CriticalOps`)

```bash
flow transactions send cadence/transactions/operations/fees/withdraw_protocol_fee.cdc \
  0 \
  50.0 \
  "Q1 treasury transfer" \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | amount | UFix64 | Amount to withdraw (capped at available balance — will not revert if requesting more than available) |
| 3 | purpose | String | Description for the log record (e.g. `"Q1 treasury transfer"`) |

Fees are sent to the signer's `/public/flowTokenReceiver`.

---

## 6. Configuration

All config changes require `ConfigOps` unless noted.

### Update draw interval (future rounds only)

Does not affect the current round:

```bash
flow transactions send cadence/transactions/operations/config/update_draw_interval.cdc \
  0 \
  604800.0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | newInterval | UFix64 | Seconds between draws — `86400.0` (daily), `604800.0` (weekly), `2592000.0` (monthly) |

### Update minimum deposit

```bash
flow transactions send cadence/transactions/operations/config/update_minimum_deposit.cdc \
  0 \
  10.0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | newMinimum | UFix64 | New minimum deposit amount in pool tokens |

### Update prize distribution — single winner

```bash
flow transactions send cadence/transactions/operations/config/update_prize_distribution_single.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

### Update prize distribution — percentage split

```bash
flow transactions send cadence/transactions/operations/config/update_prize_distribution_percentage.cdc \
  0 \
  '[0.5, 0.3, 0.2]' \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | prizeSplits | [UFix64] | Array of winner percentages, must sum to `1.0` — e.g. `'[0.6, 0.4]'` for 2 winners, `'[0.5, 0.3, 0.2]'` for 3 |

> **Warning:** Distribution changes take effect on the next `syncWithYieldSource` call. Changing mid-round alters the split for the current draw without retroactive adjustment.

### Clean up stale entries

Removes ghost entries (users who withdrew to zero). Run after draws with high churn:

```bash
flow transactions send cadence/transactions/operations/config/cleanup_stale_entries.cdc \
  0 \
  0 \
  100 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | startIndex | Int | Index to start from — `0` for first call; use `nextIndex` from previous log output to continue |
| 3 | limit | Int | Max receivers to inspect per call (100 is safe for most pools) |

Cannot be called while a draw batch is in progress. Call repeatedly if the log reports "More entries to process".

---

## 7. Emergency Operations

### Emergency states

| State | Deposits | Withdrawals | Draws |
|-------|----------|-------------|-------|
| `Normal` (0) | ✅ | ✅ | ✅ |
| `Paused` (1) | ❌ | ❌ | ❌ |
| `EmergencyMode` (2) | ❌ | ✅ | ❌ |
| `PartialMode` (3) | Limited | ✅ | ❌ |

### Enable emergency mode (requires `CriticalOps`)

```bash
flow transactions send cadence/transactions/operations/emergency/enable_emergency_mode.cdc \
  0 \
  "Yield source paused unexpectedly" \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |
| 2 | reason | String | Human-readable reason, recorded in the emitted event |

### Disable emergency mode (requires `CriticalOps`)

```bash
flow transactions send cadence/transactions/operations/emergency/disable_emergency_mode.cdc \
  0 \
  --network=mainnet \
  --signer=mainnet-ops
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | poolID | UInt64 | Pool ID |

### Auto-triggers

The contract will automatically enter `EmergencyMode` if:
- Consecutive withdrawal failures exceed `maxWithdrawFailures` (default: 3)
- Yield source health score drops below `minYieldSourceHealth`

It will auto-recover when the yield source health normalizes, if `autoRecoveryEnabled` is true (default).

---

## 8. Creating a Pool (requires `CriticalOps` + `OwnerOnly`)

Pool creation requires both entitlements and must be signed by the deployer. The yield connector is **immutable after creation**.

### Single winner pool

```bash
flow transactions send cadence/transactions/operations/pools/create_pool_single_winner.cdc \
  1.0 \
  604800.0 \
  0.5 \
  0.4 \
  0.1 \
  "flowYieldVaultsManagerV2_pool1" \
  "A.b1d63873c3cc9f79.PMStrategiesV1.FUSDEVStrategy" \
  --network=mainnet \
  --signer=mainnet-deployer
```

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 1 | minimumDeposit | UFix64 | Minimum deposit amount in pool tokens |
| 2 | drawIntervalSeconds | UFix64 | Seconds between draws — e.g. `604800.0` (weekly) |
| 3 | rewardsPercent | UFix64 | Fraction of yield to savings / share price increase — e.g. `0.5` |
| 4 | prizePercent | UFix64 | Fraction of yield to prize pool — e.g. `0.4` |
| 5 | protocolFeePercent | UFix64 | Fraction of yield to protocol treasury — e.g. `0.1` |
| 6 | pathIdentifier | String | Unique storage path suffix for the connector — must differ per pool (e.g. `"flowYieldVaultsManagerV2_pool1"`) |
| 7 | strategyTypeId | String | Fully-qualified Cadence type of the yield strategy (e.g. `"A.b1d63873c3cc9f79.PMStrategiesV1.FUSDEVStrategy"`) |

The three yield percentages (positions 3–5) must sum to `1.0`. The `pathIdentifier` must be unique across all pools to avoid storage path collisions.

Also available: `cadence/transactions/operations/pools/create_pool_percentage_split.cdc` (multiple winners with percentage split).

---

## 9. Routine Operations Checklist

### Weekly (per draw cycle)

1. Check draw status — confirm `isRoundEnded: true` and `allocatedPrizeYield > 0`:
   ```bash
   flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc 0 --network=mainnet
   ```
2. Run `start_draw_full.cdc` (block N) — starts draw and processes all batches
3. Wait at least 1 block
4. Run `start_draw_full.cdc` again (block N+1) — completes draw and starts next round
5. Verify pool state returned to `ROUND_ACTIVE`:
   ```bash
   flow scripts execute cadence/scripts/prize-linked-accounts/get_draw_status.cdc 0 --network=mainnet
   ```

### Monthly

- Check protocol fee accumulation and withdraw if needed:
  ```bash
  flow scripts execute cadence/scripts/prize-linked-accounts/get_protocol_fee_stats.cdc 0 --network=mainnet
  ```
- Run `cleanup_stale_entries.cdc` if many users have withdrawn to zero
- Review emergency state for any auto-triggered events:
  ```bash
  flow scripts execute cadence/scripts/prize-linked-accounts/get_emergency_info.cdc 0 --network=mainnet
  ```

### On yield source issues

1. Check pool stats for `emergencyState` and `availableYieldRewards`:
   ```bash
   flow scripts execute cadence/scripts/prize-linked-accounts/get_pool_stats.cdc 0 --network=mainnet
   ```
2. If `emergencyState == 2`, investigate yield source health
3. Once resolved, call `disable_emergency_mode.cdc`
4. If draw is stuck, see [docs/audit/RECOVERY.md](audit/RECOVERY.md)
