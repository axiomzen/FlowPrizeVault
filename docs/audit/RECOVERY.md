# Recovery Procedures

Contract: `PrizeLinkedAccounts.cdc`

## 1. Stuck Draw

The draw runs in 3 phases. A draw can stall at any phase boundary.

| Phase | Stall Cause | Recovery |
|-------|------------|----------|
| Phase 1: `startDraw()` | Panics (emergency auto-triggered, no prize yield, round not ended) | Fix precondition. If emergency triggered, resolve yield source, call `disableEmergencyMode()`, retry. If `allocatedPrizeYield == 0`, use `fundPoolDirect(destination: .Prize)` to seed the prize pool. |
| Phase 2: `processDrawBatch()` | Gas limits, operator stops calling | Call again with same or smaller `limit`. Batch cursor persists in `pendingSelectionData`. No timeout -- can resume at any time. |
| Phase 3: `completeDraw()` | Called same block as `startDraw()` (randomness requires 1+ block gap) | Wait one block and call again. |
| Phase 3: `completeDraw()` | Protocol fee recipient capability invalid | Fee goes to `unclaimedProtocolFeeVault` automatically (no panic). If it does panic, clear recipient: `setPoolProtocolFeeRecipient(nil)`, retry. |

There is no admin function to cancel a draw mid-flight. Once `startDraw()` succeeds:
- `pendingDrawReceipt` and `pendingSelectionData` exist as resources on the Pool.
- `activeRound` still holds the ended round with `actualEndTime` set.
- The only forward path is completing all 3 phases.
- Deposits and withdrawals remain functional during the draw.

After `completeDraw()`, the pool enters intermission. Call `startNextRound()` to begin a new round.

## 2. Yield Source Failure

### Auto-Detection

The pool monitors yield source health on every withdrawal via `checkAndAutoTriggerEmergency()`:

| Trigger | Threshold | Default |
|---------|-----------|---------|
| Health score below minimum | `minYieldSourceHealth` | 0.50 (50%) |
| Consecutive withdrawal failures | `maxWithdrawFailures` | 3 |

Health score = 50% balance check + 50% withdrawal success rate.

### What EmergencyMode Disables

| Operation | Allowed? |
|-----------|----------|
| Withdrawals | Yes |
| Deposits | No |
| Draws | No |
| Direct funding | No |
| Admin config changes | Yes |

### Auto-Recovery

Checked on every withdrawal while in EmergencyMode (if `autoRecoveryEnabled == true`):

| Condition | Action |
|-----------|--------|
| Health >= 0.90 | Immediately recover to Normal |
| Health >= `minRecoveryHealth` AND duration > `maxEmergencyDuration` | Time-based recovery |

### Manual Recovery

1. Investigate yield source off-chain.
2. Call `Admin.disableEmergencyMode(poolID)` to return to Normal.
3. Or call `Admin.setPoolState(poolID, .Normal, nil)` for the same effect.
4. Consecutive failure counter resets to 0 on recovery.

## 3. Bad Config

All config changes take effect immediately. There is no rollback mechanism.

| Config | Fix |
|--------|-----|
| Bad distribution strategy | Call `updatePoolDistributionStrategy()` with corrected strategy. Old/new names logged in `DistributionStrategyUpdated` event. |
| Bad prize distribution | Call `updatePoolPrizeDistribution()` with corrected distribution. Takes effect on next `completeDraw()`. |
| Wrong draw interval | Call `updatePoolDrawIntervalForFutureRounds()`. Only affects rounds created after the next `startDraw()`. Current round is not changed. |
| Wrong round end time | Call `updateCurrentRoundTargetEndTime()`. Can only be called before `startDraw()` on the current round. |
| Bad minimum deposit | Call `updatePoolMinimumDeposit()`. Immediate. |
| Bad protocol fee recipient | Call `setPoolProtocolFeeRecipient(nil)` to clear. Fees route to `unclaimedProtocolFeeVault`. |
| Bad emergency config | Call `updateEmergencyConfig()` with corrected config. |

All config update events include `adminUUID` for audit trail. Strategy updates include old and new names.

## 4. Emergency Procedures

### State Transitions

```
Normal <---> Paused
Normal <---> EmergencyMode
Normal <---> PartialMode
EmergencyMode --> Normal (auto-recovery)
```

Any state can be set directly via `Admin.setPoolState()`.

### Enter Emergency Mode

```
Admin.enableEmergencyMode(poolID: id, reason: "description")
// or
Admin.setPoolState(poolID: id, state: .EmergencyMode, reason: "description")
```

Emits `PoolEmergencyEnabled`. Blocks deposits and draws. Withdrawals remain open.

### Enter Partial Mode

```
Admin.setEmergencyPartialMode(poolID: id, reason: "description")
```

Allows deposits up to `partialModeDepositLimit`. Blocks draws.

### Pause (full stop)

```
Admin.setPoolState(poolID: id, state: .Paused, reason: "description")
```

Blocks all operations including withdrawals. Use only for critical contract-level issues.

### Exit Any State

```
Admin.disableEmergencyMode(poolID: id)   // EmergencyMode -> Normal
Admin.setPoolState(poolID: id, state: .Normal, nil)  // Any state -> Normal
```

Resets `consecutiveWithdrawFailures` to 0 and clears `emergencyReason` and `emergencyActivatedAt`.

### Emergency Config Defaults

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `maxEmergencyDuration` | 86400s (24h) | Max time before auto-recovery kicks in |
| `autoRecoveryEnabled` | true | Enable health-based auto-recovery |
| `minYieldSourceHealth` | 0.50 | Health threshold to trigger emergency |
| `maxWithdrawFailures` | 3 | Consecutive failures to trigger emergency |
| `partialModeDepositLimit` | 100.0 | Max deposit in partial mode |
| `minBalanceThreshold` | 0.95 | Balance ratio for health scoring |
| `minRecoveryHealth` | 0.50 | Min health for time-based recovery |

## 5. Upgrade Constraints

### Cadence Contract Update Rules (Stable Cadence)

| Change | Allowed? |
|--------|----------|
| Add new functions | Yes |
| Add new fields to resources/structs | Yes (with default values) |
| Remove fields | No |
| Change field types | No |
| Change function signatures | No |
| Change entitlement requirements | No |
| Change resource interfaces | Limited |
| Re-run `init()` | No -- runs only on first deploy |

### What Cannot Change Post-Deployment

- Storage paths (`PoolPositionCollectionStoragePath`, etc.) -- set in `init()`, never re-runs.
- Constants (`VIRTUAL_SHARES`, `VIRTUAL_ASSETS`, `SAFE_MAX_TVL`, etc.) -- `let` fields set in `init()`.
- Entitlement definitions (`ConfigOps`, `CriticalOps`, `OwnerOnly`, `PositionOps`).
- Existing resource field types or removal.
- Event parameter signatures (adding parameters is fine, removing/changing types is not).

### What Can Change Post-Deployment

- Distribution strategies and prize distributions (runtime-swappable via Admin).
- Emergency config (runtime-swappable via Admin).
- Draw intervals, minimum deposits, round targets (runtime-swappable via Admin).
- Protocol fee recipient (runtime-swappable via Admin).
- New functions, events, and struct types can be added to the contract.
- New fields with defaults can be added to existing resources.

### Migration Notes

- The contract has no admin migration function for storage paths. If paths need to change, users must manually migrate resources.
- Pool state (resources in `self.pools`) persists across upgrades. New fields added to `Pool` must have defaults or be nullable.
- The `Admin` resource has a `metadata: {String: {String: AnyStruct}}` field for future extensibility without upgrades.
