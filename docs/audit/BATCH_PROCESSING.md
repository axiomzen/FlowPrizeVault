# Batch Processing

## 1. Why Batching

Cadence transactions have execution limits (computation/memory). A pool with thousands of receivers cannot finalize all TWAB weights and select winners in a single transaction. The draw is split into three separate transactions: start, batch (repeated), and complete. Each batch call processes a bounded number of receivers, keeping per-transaction costs predictable.

## 2. processDrawBatch() Mechanics

### Entry Point

`processDrawBatch(limit: Int)` -- called repeatedly after `startDraw()`, before `completeDraw()`. Both permissionless (`access(all)`) and admin (`access(CriticalOps)`) entry points exist.

### Per-Call Flow

1. Read `cursor` from `BatchSelectionData` resource (starts at 0).
2. Calculate `endIndex = min(cursor + limit, snapshotReceiverCount)`.
3. For each receiver in `registeredReceiverList[cursor..<endIndex]`:
   - Get current shares from `ShareTracker`.
   - Call `activeRound.finalizeTWAB()` with `actualEndTime` set by `startDraw()`. Returns normalized weight (average shares over round duration).
   - Add bonus weight (if any).
   - Call `selectionData.addEntry(receiverID, totalWeight)` -- appends to `receiverIDs` array and builds cumulative weight sum on the fly.
4. Advance cursor to `endIndex`.
5. Return `snapshotReceiverCount - endIndex` (remaining count).

### Progress Tracking

| Field | Location | Purpose |
|-------|----------|---------|
| `cursor` | `BatchSelectionData` | Next index to process |
| `snapshotReceiverCount` | `BatchSelectionData` (set at `startDraw()`) | Total receivers to process (frozen at draw start) |
| `receiverIDs` / `cumulativeWeights` | `BatchSelectionData` | Parallel arrays for weighted binary search |
| `totalWeight` | `BatchSelectionData` | Running sum (cached, equals last element of `cumulativeWeights`) |

Completion check: `cursor >= snapshotReceiverCount` (via `isBatchComplete()`).

### Snapshot Isolation

`snapshotReceiverCount` is set to `registeredReceiverList.length` at `startDraw()` time. New deposits during batch processing add receivers to the end of `registeredReceiverList` but do not increase the snapshot count. Those receivers are skipped by the batch loop. This prevents a DoS vector where an attacker deposits repeatedly to extend the batch indefinitely.

## 3. Index Management

### Swap-and-Pop

`registeredReceiverList` is an array paired with `registeredReceivers` (dictionary mapping receiverID -> index). Unregistration uses swap-and-pop for O(1) removal:

1. Look up the receiver's index in the dictionary.
2. If not the last element: copy the last element into the removed position, update the moved element's dictionary entry.
3. `removeLast()` on the array.
4. Remove the receiver from the dictionary.

### Why Unregistration Is Blocked During Draws

Swap-and-pop changes array indices. During batch processing, the cursor iterates over `registeredReceiverList` by index. If a receiver at index `i < cursor` is removed and another receiver swaps into position `i`, that receiver was already processed and is now at a processed index -- no corruption. But if a receiver at index `i >= cursor` (not yet processed) is swapped to a position `< cursor` (already processed), it gets skipped entirely.

Guard (line 3855): when a user withdraws to 0 shares and `pendingSelectionData != nil`, unregistration is skipped. The receiver becomes a "ghost" entry -- still in the list but with 0 shares, producing 0 weight in batch processing. Ghosts are cleaned up via `cleanupStaleEntries()` after the draw completes.

`cleanupStaleEntries()` itself has a precondition (line 3196): `pendingSelectionData == nil` -- cannot run during an active draw.

## 4. Intermission

### Purpose

After `completeDraw()` destroys the active round, the pool enters intermission (`activeRound == nil && pendingDrawReceipt == nil`). This is a deliberate pause between rounds that allows:

- Admin to review draw results before starting a new round.
- Configuration changes (distribution strategy, draw interval) without affecting an active round.
- Cleanup operations (`cleanupStaleEntries()`).

### What Works During Intermission

| Operation | Allowed? | Notes |
|-----------|----------|-------|
| Deposit | Yes | Shares minted, no TWAB recorded (no active round) |
| Withdraw | Yes | Shares burned, no TWAB recorded |
| startDraw() | No | Precondition: `activeRound != nil` |
| startNextRound() | Yes | Creates new round, emits `IntermissionEnded` |
| Direct funding | Yes | If pool is in Normal state |
| cleanupStaleEntries() | Yes | If no pending selection data |

Intermission has no time limit. The pool stays in intermission until `startNextRound()` is called.

### TWAB Impact

Deposits/withdrawals during intermission do not record share changes in any round. When the next round starts via `startNextRound()`, all existing depositors begin accumulating TWAB from the new round's `startTime`. Their full share balance counts from that moment -- no retroactive credit for time spent in intermission.

## 5. Failure Modes

| Scenario | Effect | Recovery |
|----------|--------|----------|
| Batch processing stalls (no one calls `processDrawBatch()`) | Draw hangs indefinitely. Deposits/withdrawals still work. Unregistration blocked for ghost cleanup. | Anyone can call `processDrawBatch()` (permissionless). |
| `processDrawBatch()` called with `limit: 0` | Processes 0 receivers. Returns remaining count unchanged. No progress. | Call again with `limit > 0`. |
| `completeDraw()` called in same block as `startDraw()` | Panics. Flow's `RandomConsumer.fulfillRandomRequest()` requires a different block than the request block. | Wait one block and retry. |
| Emergency mode triggered after `startDraw()` | Draw continues. `processDrawBatch()` and `completeDraw()` have no emergency precondition. | Draw completes normally. Emergency state takes effect for subsequent operations. |
| No eligible winners (all 0 weight) | `completeDraw()` emits `PrizesAwarded` with empty arrays. `allocatedPrizeYield` carries forward to next round. Active round destroyed, pool enters intermission. | Normal. Prize accumulates. |
| Total weight exceeds `WEIGHT_WARNING_THRESHOLD` (90% of UFix64 max) | `WeightWarningThresholdExceeded` event emitted. `addEntry()` asserts weight stays below threshold -- panics if exceeded. | With normalized TWAB (weights are average shares, not share-seconds), this requires ~166 billion shares. Practically unreachable. |
| Admin calls `setPoolState(Paused)` during draw | Deposits and withdrawals blocked. `processDrawBatch()` and `completeDraw()` still execute. | Draw completes, then pool remains paused. |
