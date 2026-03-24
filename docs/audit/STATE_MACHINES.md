# State Machines

Two independent state machines govern pool behavior: **PoolEmergencyState** (operational mode) and **Round Lifecycle** (draw phase). They compose -- emergency state can override round lifecycle operations.

## 1. Pool States (PoolEmergencyState)

| State | Deposits | Withdrawals | Draws | Direct Funding | How to Enter | How to Exit |
|-------|----------|-------------|-------|----------------|--------------|-------------|
| **Normal** | Yes (min deposit enforced) | Yes | Yes | Yes | `clearEmergencyMode()`, `setState(Normal)`, auto-recovery | Default state |
| **Paused** | No | No | No | No | `setPoolState(Paused)` | `setPoolState(Normal)` (admin only) |
| **EmergencyMode** | No | Yes | No | No | `enableEmergencyMode()`, `setPoolState(EmergencyMode)`, auto-trigger | `disableEmergencyMode()`, `setPoolState(Normal)`, auto-recovery |
| **PartialMode** | Capped at `partialModeDepositLimit` | Yes | No | No | `setEmergencyPartialMode()`, `setPoolState(PartialMode)` | `setPoolState(Normal)` (admin only) |

State enforcement lives in `Pool.deposit()` (line 3545) and `Pool.withdraw()` (line 3728) via switch/assert. Draws check `emergencyState == Normal` in `startDraw()` precondition (line 4129).

## 2. Round Lifecycle (Draw Phases)

| Phase | Determined By | What Happens | Preconditions | Next Phase |
|-------|--------------|--------------|---------------|------------|
| **ROUND_ACTIVE** | `activeRound != nil && !hasEnded()` | TWAB accumulates. Deposits/withdrawals record share changes. | `startNextRound()` called | AWAITING_DRAW (automatic, when `now >= targetEndTime`) |
| **AWAITING_DRAW** | `activeRound.hasEnded() && pendingDrawReceipt == nil` | Round timer expired. Gap period. Deposits/withdrawals continue. TWAB still accumulates. | Round timer expired | DRAW_PROCESSING (via `startDraw()`) |
| **DRAW_PROCESSING** | `pendingDrawReceipt != nil` | Three sub-phases execute sequentially (see below). Deposits/withdrawals continue but don't affect the draw snapshot. | `startDraw()` called | INTERMISSION (via `completeDraw()`) |
| **INTERMISSION** | `activeRound == nil && pendingDrawReceipt == nil` | No active round. Deposits/withdrawals continue. No TWAB tracking. | `completeDraw()` called | ROUND_ACTIVE (via `startNextRound()`) |

### Draw Sub-Phases (within DRAW_PROCESSING)

| Sub-Phase | Function | What Happens | Repeat? |
|-----------|----------|--------------|---------|
| **Phase 1: Start** | `startDraw()` | Sets `actualEndTime` on round. Snapshots receiver count. Syncs yield. Materializes protocol fee. Requests randomness. Creates `PrizeDrawReceipt` and `BatchSelectionData`. | Once |
| **Phase 2: Batch** | `processDrawBatch(limit)` | Iterates receiver snapshot. Finalizes TWAB per user. Builds cumulative weight array for binary search. | Repeat until `cursor >= snapshotReceiverCount` |
| **Phase 3: Complete** | `completeDraw()` | Fulfills randomness (must be different block from Phase 1). Selects winners via weighted binary search. Auto-compounds prizes into winner deposits. Destroys active round. Enters intermission. | Once |

## 3. Emergency Auto-Triggers

Checked during withdrawals in Normal state (`checkAndAutoTriggerEmergency()`, line 3365).

| Trigger | Condition | Source |
|---------|-----------|--------|
| Low yield source health | `checkYieldSourceHealth() < emergencyConfig.minYieldSourceHealth` | Balance ratio below threshold OR withdrawal success rate degraded |
| Consecutive withdrawal failures | `consecutiveWithdrawFailures >= emergencyConfig.maxWithdrawFailures` | Yield source returns 0 or has insufficient liquidity |

Health score formula (line 3343):
- 50% weight: `yieldBalance >= userPoolBalance * minBalanceThreshold`
- 50% weight: `1.0 / (consecutiveWithdrawFailures + 1)`

`startDraw()` also runs a final health check (line 4138) and panics if emergency triggers.

## 4. Auto-Recovery

Checked during withdrawals in EmergencyMode state (`checkAndAutoRecover()`, line 3402).

| Recovery Path | Condition |
|---------------|-----------|
| Health-based | `autoRecoveryEnabled && healthScore >= 0.9` |
| Time-based | `autoRecoveryEnabled && duration > maxEmergencyDuration && healthScore >= minRecoveryHealth` |

Auto-recovery only applies to EmergencyMode. Paused and PartialMode require manual admin intervention.

## 5. State Interaction: Emergency During Draw

| Scenario | Behavior |
|----------|----------|
| Emergency triggered during ROUND_ACTIVE | Draw cannot start (`startDraw()` precondition blocks). Deposits blocked, withdrawals continue. |
| Emergency triggered during AWAITING_DRAW | Same as above. `startDraw()` also runs `checkAndAutoTriggerEmergency()` and panics if triggered. |
| Emergency triggered during DRAW_PROCESSING | `processDrawBatch()` and `completeDraw()` have no emergency precondition -- they run to completion. Deposits are blocked; withdrawals continue. The draw finishes with the existing snapshot. |
| Admin pauses during DRAW_PROCESSING | `processDrawBatch()` and `completeDraw()` still work (no Paused check). Only deposits and withdrawals are blocked. Draw can complete, then pool stays paused. |
| Unregistration during DRAW_PROCESSING | Blocked. Users withdrawing to 0 shares become "ghost" entries (0 weight, 0 prize chance). Cleaned up via `cleanupStaleEntries()` after draw. |
| Emergency during INTERMISSION | No impact on round lifecycle. Pool stays in intermission. New round cannot start until Normal (no explicit check, but `startDraw()` on next round will fail). |

The two state machines are independent: emergency state gates operations, round lifecycle gates draw progression. A draw in progress always runs to completion regardless of emergency state changes.
