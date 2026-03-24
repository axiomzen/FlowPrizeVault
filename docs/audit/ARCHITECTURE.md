# PrizeLinkedAccounts -- Architecture Reference

## Resources

| Resource | Owner | Purpose | Key Fields |
|----------|-------|---------|-----------|
| `Admin` | Contract deployer account | Privileged pool management; UUID logged in every admin event for audit trail | `metadata: {String: {String: AnyStruct}}` |
| `Pool` | Contract (`pools` dict, keyed by `poolID`) | Central coordinator: deposits, withdrawals, yield sync, draw execution, emergency state | `config: PoolConfig`, `shareTracker`, `prizeDistributor`, `activeRound`, `pendingDrawReceipt`, `pendingSelectionData`, `randomConsumer`, `registeredReceiverList`, `userPoolBalance`, `allocatedPrizeYield`, `allocatedProtocolFee`, `unclaimedProtocolFeeVault`, `emergencyState` |
| `ShareTracker` | Nested inside `Pool` | ERC4626-style share ledger with virtual offset (0.0001) for inflation attack protection | `totalShares`, `totalAssets`, `userShares: {UInt64: UFix64}`, `totalDistributed` |
| `Round` | Nested inside `Pool` (one active at a time) | Per-round TWAB tracking using fixed 1-year scale, normalized at finalization | `roundID`, `startTime`, `targetEndTime`, `actualEndTime`, `userScaledTWAB`, `userLastUpdateTime`, `userSharesAtLastUpdate`, `TWAB_SCALE = 31536000.0` |
| `PrizeDistributor` | Nested inside `Pool` | Holds FT prize vault, available NFT prizes, and pending NFT claims per winner | `prizeVault`, `nftPrizes: {UInt64: NFT}`, `pendingNFTClaims: {UInt64: [NFT]}`, `_prizeRound` |
| `PrizeDrawReceipt` | Nested inside `Pool` (exists only during active draw) | Holds committed prize amount and randomness request between startDraw and completeDraw | `prizeAmount: UFix64`, `request: RandomConsumer.Request?` |
| `BatchSelectionData` | Nested inside `Pool` (exists only during active draw) | Cumulative weight array for O(log n) binary search winner selection | `receiverIDs`, `cumulativeWeights`, `totalWeight`, `cursor`, `snapshotReceiverCount` |
| `PoolPositionCollection` | User account storage | User's prize-eligible position; UUID is the receiverID key for all pool state | `registeredPools: {UInt64: Bool}` |
| `SponsorPositionCollection` | User account storage | Sponsor's prize-ineligible position; same share mechanics, no TWAB, no draw eligibility | `registeredPools: {UInt64: Bool}` |

## Strategy Interfaces

| Interface | Method(s) | Purpose |
|-----------|----------|---------|
| `DistributionStrategy` (struct interface) | `calculateDistribution(totalAmount) -> DistributionPlan`, `getStrategyName() -> String` | Determines how yield splits between rewards, prize, protocol fee |
| `PrizeDistribution` (struct interface) | `getWinnerCount() -> Int`, `distributePrizes(winners, totalPrizeAmount) -> WinnerSelectionResult`, `getDistributionName() -> String` | Determines prize amount/NFT allocation per winner position |

**Concrete implementations:**

| Struct | Implements | Behavior |
|--------|-----------|----------|
| `FixedPercentageStrategy` | `DistributionStrategy` | Fixed reward/prize/fee percentages summing to 1.0; protocol fee gets remainder to absorb rounding |
| `SingleWinnerPrize` | `PrizeDistribution` | One winner gets 100% of prize pool + all configured NFTs |
| `PercentageSplit` | `PrizeDistribution` | N winners get percentage-based splits (e.g., 50/30/20); last winner gets remainder to absorb rounding |

## Entitlements

| Entitlement | Guards | Delegation Policy |
|-------------|--------|-------------------|
| `ConfigOps` | Draw intervals, minimum deposit, bonus weights, NFT prize deposit/withdraw, cleanup, process rewards, start next round | Safe to issue as capability to operators |
| `CriticalOps` | Pool creation, distribution/prize strategy changes, emergency mode, draw phases, direct funding, protocol fee withdrawal, pool state changes | Issue only to trusted admin accounts |
| `OwnerOnly` | `setPoolProtocolFeeRecipient` (redirects protocol fee income) | NEVER issue as capability; storage borrow only. For multi-sig, store Admin in a multi-sig account |
| `PositionOps` | `deposit`, `withdraw`, `claimPendingNFT` on position collections | Issued to user via capability from their stored collection resource |

## Storage and Capabilities

| Path | Type | Resource / Capability | Access | Notes |
|------|------|----------------------|--------|-------|
| `/storage/PrizeLinkedAccountsCollection` | StoragePath | `PoolPositionCollection` | Owner | UUID = receiverID for all pool operations |
| `/public/PrizeLinkedAccountsCollection` | PublicPath | Read-only capability | Anyone | Balance queries, entry counts, pending NFT info |
| `/storage/PrizeLinkedAccountsSponsorCollection` | StoragePath | `SponsorPositionCollection` | Owner | Same account can hold both position and sponsor collections |
| `/public/PrizeLinkedAccountsSponsorCollection` | PublicPath | Read-only capability | Anyone | Balance queries |
| `/storage/PrizeLinkedAccountsAdmin` | StoragePath | `Admin` | Contract deployer | Single Admin created at contract init; capabilities scoped per entitlement |

Contract-level state (not in user storage):

| State | Type | Access | Notes |
|-------|------|--------|-------|
| `pools` | `@{UInt64: Pool}` | `access(self)` | All pools keyed by auto-incrementing ID |
| `nextPoolID` | `UInt64` | `access(self)` | Monotonically increasing counter |

## Resource Lifecycle

**Admin**: Created once in contract `init()`, saved to deployer's storage at `AdminStoragePath`. Never destroyed. Capabilities with specific entitlements (`ConfigOps`, `CriticalOps`) can be issued from storage. `OwnerOnly` must never be issued as a capability.

**Pool**: Created by `Admin.createPool()` via `access(CriticalOps)`. Stored in contract-level `pools` dictionary. Contains nested resources (`ShareTracker`, `PrizeDistributor`, `RandomConsumer.Consumer`) created in Pool's `init()`. No explicit destroy path exists -- pools persist for the contract's lifetime. Cadence 1.0 auto-destroys nested resources.

**Round**: Created inside `Pool.init()` (round 1) and `Pool.startNextRound()`. One active at a time (`activeRound`). `startDraw()` sets `actualEndTime`, freezing TWAB accumulation. `completeDraw()` destroys the round after TWAB data is consumed. Pool enters intermission (no active round) until `startNextRound()`.

**PrizeDrawReceipt**: Created during `startDraw()` with committed prize amount and `RandomConsumer.Request`. Consumed and destroyed during `completeDraw()` after randomness fulfillment. Exists only between phases 1 and 3.

**BatchSelectionData**: Created during `startDraw()` with snapshotted receiver count. Built incrementally by `processDrawBatch()` (cumulative weight array). Referenced by `completeDraw()` for binary search winner selection. Destroyed after `completeDraw()`.

**PoolPositionCollection**: Created by `createPoolPositionCollection()` (contract-level `access(all)`). User stores in their account. UUID becomes their permanent receiverID. Auto-registers with pools on first deposit. If destroyed, all funds keyed to that UUID become inaccessible (no built-in recovery).

**SponsorPositionCollection**: Created by `createSponsorPositionCollection()`. Same lifecycle as `PoolPositionCollection`. Marked in `Pool.sponsorReceivers` on first deposit. Not added to `registeredReceiverList`, so never processed during draws.
