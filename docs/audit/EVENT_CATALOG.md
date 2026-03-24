# Event Catalog

Contract: `PrizeLinkedAccounts.cdc`

## Core Operations

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `PoolCreated` | poolID, assetType, strategy | `createPool()` (contract-level) | Core Ops |
| `Deposited` | poolID, receiverID, amount, shares, ownerAddress? | `Pool.deposit()` | Core Ops |
| `SponsorDeposited` | poolID, receiverID, amount, shares, ownerAddress? | `Pool.sponsorDeposit()` | Core Ops |
| `Withdrawn` | poolID, receiverID, requestedAmount, actualAmount, ownerAddress? | `Pool.withdraw()` | Core Ops |
| `DepositSlippage` | poolID, nominalAmount, actualReceived, slippage | `Pool.applyExcess()` | Core Ops |
| `WithdrawalFailure` | poolID, receiverID, amount, consecutiveFailures, yieldAvailable, ownerAddress? | `Pool.withdraw()` | Core Ops |

## Reward Processing

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `RewardsProcessed` | poolID, totalAmount, rewardsAmount, prizeAmount | `Pool.applyExcess()` | Rewards |
| `RewardsYieldAccrued` | poolID, amount | `Pool.applyExcess()`, `Pool.fundDirectInternal()` | Rewards |
| `RewardsRoundingDustToProtocolFee` | poolID, amount | `Pool.applyExcess()`, `Pool.fundDirectInternal()` | Rewards |
| `DeficitApplied` | poolID, totalDeficit, absorbedByProtocolFee, absorbedByPrize, absorbedByRewards | `Pool.applyDeficit()` | Rewards |
| `InsolvencyDetected` | poolID, unreconciledAmount | `Pool.applyDeficit()` | Rewards |

## Draw Lifecycle

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `DrawBatchStarted` | poolID, endedRoundID, newRoundID, totalReceivers | `Pool.startDraw()` | Draw |
| `DrawRandomnessRequested` | poolID, totalWeight, prizeAmount, commitBlock | `Pool.startDraw()` | Draw |
| `DrawBatchProcessed` | poolID, processed, remaining | `Pool.processDrawBatch()` | Draw |
| `WeightWarningThresholdExceeded` | poolID, totalWeight, warningThreshold, percentOfMax | `Pool.processDrawBatch()` | Draw |
| `PrizesAwarded` | poolID, winners[], winnerAddresses[]?, amounts[], round | `Pool.completeDraw()` | Draw |
| `IntermissionStarted` | poolID, completedRoundID, prizePoolBalance | `Pool.completeDraw()` | Draw |
| `IntermissionEnded` | poolID, newRoundID, roundDuration | `Pool.startNextRound()` | Draw |
| `PrizePoolFunded` | poolID, amount, source | `Pool.fundDirectInternal()`, `Pool.applyExcess()` | Draw |

## Admin Configuration

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `PoolCreatedByAdmin` | poolID, assetType, strategy, adminUUID | `Admin.createPool()` | Admin Config |
| `DistributionStrategyUpdated` | poolID, oldStrategy, newStrategy, adminUUID | `Admin.updatePoolDistributionStrategy()` | Admin Config |
| `PrizeDistributionUpdated` | poolID, oldDistribution, newDistribution, adminUUID | `Admin.updatePoolPrizeDistribution()` | Admin Config |
| `FutureRoundsIntervalUpdated` | poolID, oldInterval, newInterval, adminUUID | `Admin.updatePoolDrawIntervalForFutureRounds()` | Admin Config |
| `RoundTargetEndTimeUpdated` | poolID, roundID, oldTarget, newTarget, adminUUID | `Admin.updateCurrentRoundTargetEndTime()` | Admin Config |
| `MinimumDepositUpdated` | poolID, oldMinimum, newMinimum, adminUUID | `Admin.updatePoolMinimumDeposit()` | Admin Config |
| `PoolStorageCleanedUp` | poolID, ghostReceivers, userShares, pendingNFTClaims, nextIndex, totalReceivers, adminUUID | `Admin.cleanupPoolStaleEntries()` | Admin Config |

## Emergency & State

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `PoolPaused` | poolID, adminUUID, reason | `Admin.setPoolState()` | Emergency |
| `PoolUnpaused` | poolID, adminUUID | `Admin.setPoolState()` | Emergency |
| `PoolEmergencyEnabled` | poolID, reason, adminUUID, timestamp | `Admin.enableEmergencyMode()`, `Admin.setPoolState()` | Emergency |
| `PoolEmergencyDisabled` | poolID, adminUUID, timestamp | `Admin.disableEmergencyMode()` | Emergency |
| `PoolPartialModeEnabled` | poolID, reason, adminUUID, timestamp | `Admin.setEmergencyPartialMode()`, `Admin.setPoolState()` | Emergency |
| `EmergencyModeAutoTriggered` | poolID, reason, healthScore, timestamp | `Pool.checkAndAutoTriggerEmergency()` | Emergency |
| `EmergencyModeAutoRecovered` | poolID, reason, healthScore?, duration?, timestamp | `Pool.checkAndAutoRecover()` | Emergency |
| `EmergencyConfigUpdated` | poolID, adminUUID | `Admin.updateEmergencyConfig()` | Emergency |

## NFT Prizes

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `NFTPrizeDeposited` | poolID, nftID, nftType, adminUUID | `Admin.depositNFTPrize()` | NFT |
| `NFTPrizeAwarded` | poolID, receiverID, nftID, nftType, round, ownerAddress? | `Pool.completeDraw()` | NFT |
| `NFTPrizeStored` | poolID, receiverID, nftID, nftType, reason, ownerAddress? | `Pool.completeDraw()` | NFT |
| `NFTPrizeClaimed` | poolID, receiverID, nftID, nftType, ownerAddress? | `Pool.claimPendingNFT()` | NFT |
| `NFTPrizeWithdrawn` | poolID, nftID, nftType, adminUUID | `Admin.withdrawNFTPrize()` | NFT |

## Bonus Weights

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `BonusPrizeWeightSet` | poolID, receiverID, bonusWeight, reason, adminUUID, timestamp, ownerAddress? | `Pool.setBonusWeight()` | Bonus |
| `BonusPrizeWeightAdded` | poolID, receiverID, additionalWeight, newTotalBonus, reason, adminUUID, timestamp, ownerAddress? | `Pool.addBonusWeight()` | Bonus |
| `BonusPrizeWeightRemoved` | poolID, receiverID, previousBonus, adminUUID, timestamp, ownerAddress? | `Pool.removeBonusWeight()` | Bonus |

## Funding

| Event | Parameters | Emitted By | Category |
|-------|-----------|------------|----------|
| `ProtocolFeeFunded` | poolID, amount, source | `Pool.applyExcess()` | Funding |
| `ProtocolFeeRecipientUpdated` | poolID, newRecipient?, adminUUID | `Admin.setPoolProtocolFeeRecipient()` | Funding |
| `ProtocolFeeForwarded` | poolID, amount, recipient | `Pool.startDraw()`, `Admin.withdrawUnclaimedProtocolFee()` | Funding |
| `DirectFundingReceived` | poolID, destination, destinationName, amount, adminUUID, purpose, metadata | `Admin.fundPoolDirect()` | Funding |

## State-Changing Functions Without Events

| Function | What It Does | Risk |
|----------|-------------|------|
| `Pool.registerReceiver()` | Adds user to receiver list on first deposit | Low -- covered by `Deposited` event |
| `Pool.unregisterReceiver()` | Removes user on full withdrawal (swap-and-pop) | Low -- covered by `Withdrawn` event |
| `Admin.processPoolRewards()` | Triggers `syncWithYieldSource()` | Low -- sync emits `RewardsProcessed` or `DeficitApplied` if yield changed |
| `Admin.startNextRound()` | Delegates to `Pool.startNextRound()` | None -- `IntermissionEnded` emitted by pool |
| `Pool.setProtocolFeeRecipient()` | Updates internal cap | None -- `ProtocolFeeRecipientUpdated` emitted by Admin caller |
| `Pool.setState()` | Sets emergency state fields | None -- events emitted by Admin caller |

Total: 42 event types declared, all state-changing admin operations emit at least one event.
