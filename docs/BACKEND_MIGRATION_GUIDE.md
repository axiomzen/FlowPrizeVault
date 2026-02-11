# Backend Migration Guide: PrizeSavings → PrizeLinkedAccounts

Migration reference for the backend team. All items reference contract-level functions, variables, and types on `PrizeLinkedAccounts` deployed at `0xa092c4aab33daeda`.

---

## 1. Contract Name

| Before | After |
|--------|-------|
| `PrizeSavings` | `PrizeLinkedAccounts` |

All import paths, type references, and event namespaces change accordingly.

---

## 2. User Collection Storage Paths

| Before | After |
|--------|-------|
| `PrizeSavings.UserCollectionStoragePath` | `PrizeLinkedAccounts.PoolPositionCollectionStoragePath` |
| `PrizeSavings.UserCollectionPublicPath` | `PrizeLinkedAccounts.PoolPositionCollectionPublicPath` |

The resource type changes from `UserCollection` to `PoolPositionCollection`.

---

## 3. Deposit Function Signature

The `deposit()` function on `PoolPositionCollection` now requires a `maxSlippageBps` parameter:

```
Before:  deposit(poolID: UInt64, from: @{FungibleToken.Vault})
After:   deposit(poolID: UInt64, from: @{FungibleToken.Vault}, maxSlippageBps: UInt64)
```

- `maxSlippageBps` — maximum acceptable slippage in basis points (e.g., `100` = 1%)
- Protects users against share-price manipulation during deposit
- Recommended default: `100` (1%) for normal conditions

---

## 4. Draw Cycle (4 Phases)

The draw cycle changed from a single `executeDraw()` call to a 4-phase process.

### Phases

| # | Phase | Admin Function | Pool State |
|---|-------|---------------|------------|
| 1 | Start draw | `Admin.startDraw(poolID)` | `AWAITING_DRAW` |
| 2 | Process batches | `Admin.processDrawBatch(poolID, batchSize)` | `DRAW_PROCESSING` |
| 3 | Request randomness | `Admin.requestDrawRandomness(poolID)` | `DRAW_PROCESSING` |
| 4 | Complete draw | `Admin.completeDraw(poolID, maxWinners)` | `INTERMISSION` → `ROUND_ACTIVE` |

### Querying Draw State

**Pool state machine** — use `Pool` view functions via a pool reference from `PrizeLinkedAccounts.borrowPool(poolID)`:

| Function | Returns | Description |
|----------|---------|-------------|
| `isRoundActive()` | `Bool` | Round is live, deposits/withdrawals allowed |
| `isAwaitingDraw()` | `Bool` | Round ended, waiting for batch processing |
| `isDrawInProgress()` | `Bool` | Batch processing or randomness pending |
| `isInIntermission()` | `Bool` | Between rounds, deposits/withdrawals allowed |
| `getPoolState()` | `String` | One of: `"ROUND_ACTIVE"`, `"AWAITING_DRAW"`, `"DRAW_PROCESSING"`, `"INTERMISSION"` |
| `getRoundTargetEndTime()` | `UFix64` | Earliest time `startDraw()` can be called |
| `getCurrentRoundID()` | `UInt64` | Active round number |

**Contract-level convenience functions** (no pool reference needed):

| Function | Returns |
|----------|---------|
| `PrizeLinkedAccounts.getPoolState(poolID)` | `String?` |
| `PrizeLinkedAccounts.isRoundActive(poolID)` | `Bool` |
| `PrizeLinkedAccounts.isDrawInProgress(poolID)` | `Bool` |

---

## 5. Terminology Renames

| PrizeSavings | PrizeLinkedAccounts | Notes |
|-------------|---------------------|-------|
| `UserCollection` | `PoolPositionCollection` | User deposit resource |
| `executeDraw()` | 4-phase draw (see above) | No single-call equivalent |
| `yieldAmount` | `allocatedRewards` | Savings portion of yield |
| `lotteryAmount` | `allocatedPrizeYield` | Prize pool portion of yield |
| `protocolFees` | `allocatedProtocolFee` | Treasury portion of yield |
| `totalDeposited` | `shareTracker.getTotalAssets()` | Total user assets tracked via shares |
| `UserPosition` | `PoolPosition` | Individual user position in a pool |
| `SavingsDistributor` | `ShareTracker` | Internal; not directly queried |
| `LotteryDistributor` | `PrizeDistributor` | Internal; not directly queried |

---

## 6. Event Signature Changes

| PrizeSavings Event | PrizeLinkedAccounts Event | Key Changes |
|-------------------|--------------------------|-------------|
| `Deposited(poolID, address, amount)` | `Deposited(poolID, receiverID, amount, sharesIssued, sharePrice, ...)` | Added share accounting fields |
| `Withdrawn(poolID, address, amount)` | `Withdrawn(poolID, receiverID, requestedAmount, actualAmount, sharesRedeemed, sharePrice, ...)` | Distinguishes requested vs actual amount; adds share fields |
| `DrawCompleted(poolID, ...)` | `DrawCompleted(poolID, roundID, totalPrizePool, winnerCount, ...)` | Added round tracking |
| `PrizeAwarded(poolID, address, amount)` | `PrizeAwarded(poolID, roundID, receiverID, amount, tier, ...)` | Added round/tier info |
| — | `DrawPhaseChanged(poolID, roundID, phase)` | New — emitted at each phase transition |
| — | `YieldSynced(poolID, yieldAmount, rewardsAmount, prizeAmount, protocolFeeAmount)` | New — emitted when yield is distributed |

---

## 7. Pool Query Functions

Available on a `Pool` reference via `PrizeLinkedAccounts.borrowPool(poolID)`:

| Function | Returns | Description |
|----------|---------|-------------|
| `getPoolStats()` | `PoolStats` | Aggregate pool statistics (total assets, shares, allocated amounts) |
| `getTotalAllocatedFunds()` | `UFix64` | Sum of rewards + prize + protocol fee allocations |
| `getYieldSourceBalance()` | `UFix64` | Current balance held in the yield source |
| `getUserAssetValue(receiverID)` | `UFix64` | User's current balance based on last-synced share price |
| `getUserShares(receiverID)` | `UFix64` | User's raw share count |
| `getSharePrice()` | `UFix64` | Current share price (assets / shares with virtual offset) |
| `getRegisteredReceiverIDs()` | `[UInt64]` | All receiver IDs registered in the current round |
| `getReceiverCount()` | `Int` | Number of registered receivers |
| `getMinimumDeposit()` | `UFix64` | Minimum deposit amount for the pool |
| `getDrawInterval()` | `UFix64` | Seconds between draws |
| `getDistributionStrategy()` | `{DistributionStrategy}` | Current yield split configuration |

**Contract-level convenience functions** (no pool reference needed):

| Function | Returns | Description |
|----------|---------|-------------|
| `PrizeLinkedAccounts.borrowPool(poolID)` | `&Pool?` | Public pool reference |
| `PrizeLinkedAccounts.getPoolIDs()` | `[UInt64]` | All active pool IDs |
| `PrizeLinkedAccounts.getPoolState(poolID)` | `String?` | Pool state string |
| `PrizeLinkedAccounts.isRoundActive(poolID)` | `Bool` | Whether round is active |
| `PrizeLinkedAccounts.isDrawInProgress(poolID)` | `Bool` | Whether draw is in progress |
