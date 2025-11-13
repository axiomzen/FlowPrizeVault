/*
PrizeVaultModular - Modular Prize-Linked Savings System

A no-loss lottery where users deposit tokens to earn:
1. Savings Interest - Distributed proportionally to all depositors
2. Lottery Prizes - Random weighted draws for bonus rewards

Key Features:
- Multiple reward sources (yield, contributions, sponsorships)
- Configurable distribution strategies (savings/lottery split)
- Time-weighted interest distribution (O(1) gas complexity)
- Flexible yield generation via DeFi Actions
*/

import "FungibleToken"
import "FlowToken"
import "RandomConsumer"
import "DeFiActions"
import "PrizeWinnerTracker"

access(all) contract PrizeVaultModular {
    
    // ========================================
    // Storage Paths
    // ========================================
    
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event RewardsCollected(poolID: UInt64, sourceID: String, amount: UFix64)
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    access(all) event RewardContributed(poolID: UInt64, contributor: Address, amount: UFix64)
    
    access(all) event SavingsInterestDistributed(poolID: UInt64, amount: UFix64, interestPerShare: UFix64)
    access(all) event SavingsInterestClaimed(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, updatedBy: Address)
    access(all) event RewardSourceRegistered(poolID: UInt64, sourceID: String, sourceName: String, updatedBy: Address)
    access(all) event RewardSourceRemoved(poolID: UInt64, sourceID: String, updatedBy: Address)
    access(all) event PoolCreatedByAdmin(poolID: UInt64, assetType: String, strategy: String, createdBy: Address)
    access(all) event YieldSinkUpdated(poolID: UInt64, updatedBy: Address)
    access(all) event YieldSourceUpdated(poolID: UInt64, updatedBy: Address)
    
    // ========================================
    // Pool Storage
    // ========================================
    
    access(self) var pools: @{UInt64: Pool}
    access(self) var nextPoolID: UInt64
    
    // ========================================
    // Admin Access Control (Resource-Based)
    // ========================================
    
    /// Admin resource that must be held to perform admin operations
    /// This follows Flow's resource-oriented programming model
    access(all) resource Admin {
        /// Create a new admin resource (only callable during contract initialization)
        init() {}
        
        /// Update the distribution strategy for a pool
        access(all) fun updatePoolDistributionStrategy(
            poolID: UInt64,
            newStrategy: {DistributionStrategy},
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let oldStrategyName = poolRef.getDistributionStrategyName()
            poolRef.setDistributionStrategy(strategy: newStrategy)
            let newStrategyName = newStrategy.getStrategyName()
            
            emit DistributionStrategyUpdated(
                poolID: poolID,
                oldStrategy: oldStrategyName,
                newStrategy: newStrategyName,
                updatedBy: updatedBy
            )
        }
        
        /// Update the winner selection strategy for a pool
        access(all) fun updatePoolWinnerSelectionStrategy(
            poolID: UInt64,
            newStrategy: {WinnerSelectionStrategy},
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let oldStrategyName = poolRef.getWinnerSelectionStrategyName()
            poolRef.setWinnerSelectionStrategy(strategy: newStrategy)
            let newStrategyName = newStrategy.getStrategyName()
            
            emit WinnerSelectionStrategyUpdated(
                poolID: poolID,
                oldStrategy: oldStrategyName,
                newStrategy: newStrategyName,
                updatedBy: updatedBy
            )
        }
        
        /// Update the winner tracker for a pool
        access(all) fun updatePoolWinnerTracker(
            poolID: UInt64,
            newTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?,
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let hasOldTracker = poolRef.hasWinnerTracker()
            poolRef.setWinnerTrackerCap(cap: newTrackerCap)
            let hasNewTracker = newTrackerCap != nil
            
            emit WinnerTrackerUpdated(
                poolID: poolID,
                hasOldTracker: hasOldTracker,
                hasNewTracker: hasNewTracker,
                updatedBy: updatedBy
            )
        }
        
        /// Update the yield sink for a pool
        access(all) fun updatePoolYieldSink(
            poolID: UInt64,
            newYieldSink: {DeFiActions.Sink},
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setYieldSink(sink: newYieldSink)
            
            emit YieldSinkUpdated(
                poolID: poolID,
                updatedBy: updatedBy
            )
        }
        
        /// Update the yield source for a pool
        access(all) fun updatePoolYieldSource(
            poolID: UInt64,
            newYieldSource: {DeFiActions.Source},
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setYieldSource(source: newYieldSource)
            
            emit YieldSourceUpdated(
                poolID: poolID,
                updatedBy: updatedBy
            )
        }
        
        /// Create a new pool (admin-only)
        access(all) fun createPool(
            config: PoolConfig,
            createdBy: Address
        ): UInt64 {
            let poolID = PrizeVaultModular.createPool(config: config)
            
            emit PoolCreatedByAdmin(
                poolID: poolID,
                assetType: config.assetType.identifier,
                strategy: config.distributionStrategy.getStrategyName(),
                createdBy: createdBy
            )
            
            return poolID
        }
        
        /// Process rewards for a pool (admin convenience function, though can also be called by anyone via pool)
        access(all) fun processPoolRewards(poolID: UInt64) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.processRewards()
        }
        
        /// Transfer admin resource to another account
        /// This allows the admin to delegate control
        /// Note: This function creates a new admin for the target account.
        /// The current admin remains in the original account's storage.
        access(all) fun transferAdmin(to: auth(Storage) &Account) {
            // Create a new admin resource and save it to the target account
            let newAdmin <- PrizeVaultModular.createAdmin()
            to.storage.save(<- newAdmin, to: PrizeVaultModular.AdminStoragePath)
            // Note: The original admin remains in the caller's storage
            // To fully transfer, the caller should manually remove their admin resource
        }
    }
    
    /// Storage path for Admin resource in user accounts
    access(all) let AdminStoragePath: StoragePath
    
    /// Public path for Admin capability (optional, for delegation)
    access(all) let AdminPublicPath: PublicPath
    
    // ========================================
    // Distribution Strategy
    // ========================================
    
    access(all) struct DistributionPlan {
        access(all) let savingsAmount: UFix64
        access(all) let lotteryAmount: UFix64
        access(all) let treasuryAmount: UFix64
        
        init(savings: UFix64, lottery: UFix64, treasury: UFix64) {
            self.savingsAmount = savings
            self.lotteryAmount = lottery
            self.treasuryAmount = treasury
        }
    }
    
    access(all) struct interface DistributionStrategy {
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan
        access(all) fun getStrategyName(): String
    }
    
    access(all) struct FixedPercentageStrategy: DistributionStrategy {
        access(all) let savingsPercent: UFix64
        access(all) let lotteryPercent: UFix64
        access(all) let treasuryPercent: UFix64
        
        init(savings: UFix64, lottery: UFix64, treasury: UFix64) {
            pre {
                savings + lottery + treasury == 1.0: "Percentages must sum to 1.0"
                savings >= 0.0 && lottery >= 0.0 && treasury >= 0.0: "Must be non-negative"
            }
            self.savingsPercent = savings
            self.lotteryPercent = lottery
            self.treasuryPercent = treasury
        }
        
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan {
            return DistributionPlan(
                savings: totalAmount * self.savingsPercent,
                lottery: totalAmount * self.lotteryPercent,
                treasury: totalAmount * self.treasuryPercent
            )
        }
        
        access(all) fun getStrategyName(): String {
            return "Fixed: "
                .concat(self.savingsPercent.toString())
                .concat(" savings, ")
                .concat(self.lotteryPercent.toString())
                .concat(" lottery")
        }
    }
    
    // ========================================
    // Reward Sources
    // ========================================
    
    access(all) resource interface RewardSource {
        access(all) fun getAvailableRewards(): UFix64
        access(all) fun collectRewards(): @{FungibleToken.Vault}
        access(all) fun getSourceName(): String
    }
    
    access(all) resource YieldRewardSource: RewardSource {
        access(self) let yieldSource: {DeFiActions.Source}
        access(self) let priceOracle: {DeFiActions.PriceOracle}?
        access(self) let assetType: Type
        access(self) var totalStaked: UFix64
        
        init(yieldSource: {DeFiActions.Source}, priceOracle: {DeFiActions.PriceOracle}?, assetType: Type) {
            self.yieldSource = yieldSource
            self.priceOracle = priceOracle
            self.assetType = assetType
            self.totalStaked = 0.0
        }
        
        access(contract) fun updateStaked(amount: UFix64) {
            self.totalStaked = amount
        }
        
        access(all) fun getAvailableRewards(): UFix64 {
            let yieldBalance = self.yieldSource.minimumAvailable()
            
            if let oracle = self.priceOracle {
                if let rate = oracle.price(ofToken: self.assetType) {
                    let totalValue = yieldBalance * rate
                    return totalValue > self.totalStaked ? totalValue - self.totalStaked : 0.0
                }
            }
            
            return yieldBalance > self.totalStaked ? yieldBalance - self.totalStaked : 0.0
        }
        
        access(all) fun collectRewards(): @{FungibleToken.Vault} {
            let available = self.getAvailableRewards()
            if available == 0.0 {
                return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            }
            return <- self.yieldSource.withdrawAvailable(maxAmount: available)
        }
        
        access(all) fun getSourceName(): String {
            return "Yield Generation"
        }
    }
    
    access(all) resource DirectContributionSource: RewardSource {
        access(self) var contributionVault: @{FungibleToken.Vault}
        access(self) let contributions: {Address: UFix64}
        access(all) var totalContributed: UFix64
        
        init(vaultType: Type) {
            self.contributionVault <- FlowToken.createEmptyVault(vaultType: vaultType)
            self.contributions = {}
            self.totalContributed = 0.0
        }
        
        access(contract) fun contribute(from: @{FungibleToken.Vault}, contributor: Address) {
            let amount = from.balance
            self.contributionVault.deposit(from: <- from)
            
            let current = self.contributions[contributor] ?? 0.0
            self.contributions[contributor] = current + amount
            self.totalContributed = self.totalContributed + amount
        }
        
        access(all) fun getAvailableRewards(): UFix64 {
            return self.contributionVault.balance
        }
        
        access(all) fun collectRewards(): @{FungibleToken.Vault} {
            let amount = self.contributionVault.balance
            if amount == 0.0 {
                return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            }
            return <- self.contributionVault.withdraw(amount: amount)
        }
        
        access(all) fun getSourceName(): String {
            return "Direct Contributions"
        }
        
        access(all) fun getContributorAmount(address: Address): UFix64 {
            return self.contributions[address] ?? 0.0
        }
    }
    
    // ========================================
    // Reward Aggregator
    // ========================================
    
    access(all) resource RewardAggregator {
        access(self) let sources: @{String: {RewardSource}}
        access(self) var collectedVault: @{FungibleToken.Vault}
        
        init(vaultType: Type) {
            self.sources <- {}
            self.collectedVault <- FlowToken.createEmptyVault(vaultType: vaultType)
        }
        
        access(contract) fun registerSource(id: String, source: @{RewardSource}) {
            pre {
                self.sources[id] == nil: "Source already registered"
            }
            self.sources[id] <-! source
        }
        
        access(contract) fun removeSource(id: String) {
            pre {
                self.sources[id] != nil: "Source not registered"
            }
            destroy self.sources.remove(key: id)!
        }
        
        access(contract) fun borrowSource(id: String): &{RewardSource}? {
            return &self.sources[id] as &{RewardSource}?
        }
        
        access(contract) fun collectAllRewards() {
            for id in self.sources.keys {
                let sourceRef = &self.sources[id] as &{RewardSource}?
                if sourceRef != nil {
                    let available = sourceRef!.getAvailableRewards()
                    if available > 0.0 {
                        let rewards <- sourceRef!.collectRewards()
                        self.collectedVault.deposit(from: <- rewards)
                    }
                }
            }
        }
        
        access(all) fun getCollectedBalance(): UFix64 {
            return self.collectedVault.balance
        }
        
        access(contract) fun withdrawCollected(amount: UFix64): @{FungibleToken.Vault} {
            return <- self.collectedVault.withdraw(amount: amount)
        }
    }
    
    // ========================================
    // Savings Distributor
    // ========================================
    
    access(all) resource SavingsDistributor {
        access(self) let PRECISION: UFix64
        access(self) var accumulatedInterestPerShare: UFix64
        access(self) let userClaimedAmount: {UInt64: UFix64}
        access(self) var interestVault: @{FungibleToken.Vault}
        access(all) var totalDistributed: UFix64
        
        init(vaultType: Type) {
            // Use 1e10 for precision - balances accuracy with UFix64 overflow safety
            // UFix64 max ≈ 184 billion, so this allows for large pools without overflow
            self.PRECISION = 10000000000.0  // 1e10
            self.accumulatedInterestPerShare = 0.0
            self.userClaimedAmount = {}
            self.interestVault <- FlowToken.createEmptyVault(vaultType: vaultType)
            self.totalDistributed = 0.0
        }
        
        access(contract) fun distributeInterest(vault: @{FungibleToken.Vault}, totalDeposited: UFix64): UFix64 {
            let amount = vault.balance
            
            if amount == 0.0 || totalDeposited == 0.0 {
                self.interestVault.deposit(from: <- vault)
                return 0.0
            }
            
            let interestPerShare = (amount * self.PRECISION) / totalDeposited
            self.accumulatedInterestPerShare = self.accumulatedInterestPerShare + interestPerShare
            
            self.interestVault.deposit(from: <- vault)
            self.totalDistributed = self.totalDistributed + amount
            
            return interestPerShare
        }
        
        access(contract) fun initializeReceiver(receiverID: UInt64, deposit: UFix64) {
            // Initialize if entry doesn't exist
            // If entry exists, it means user had a deposit before (even if they withdrew everything)
            // In that case, we should re-initialize to prevent claiming past interest on the new deposit
            if self.userClaimedAmount[receiverID] == nil {
                self.userClaimedAmount[receiverID] = (deposit * self.accumulatedInterestPerShare) / self.PRECISION
            } else {
                // User is redepositing after withdrawing everything
                // Re-initialize to set their entry point to current accumulatedInterestPerShare
                // This prevents them from claiming interest earned before this new deposit
                self.userClaimedAmount[receiverID] = (deposit * self.accumulatedInterestPerShare) / self.PRECISION
            }
        }
        
        access(all) fun calculatePendingInterest(receiverID: UInt64, deposit: UFix64): UFix64 {
            if deposit == 0.0 {
                return 0.0
            }
            
            let totalEarned = (deposit * self.accumulatedInterestPerShare) / self.PRECISION
            let alreadyClaimed = self.userClaimedAmount[receiverID] ?? 0.0
            
            return totalEarned > alreadyClaimed ? totalEarned - alreadyClaimed : 0.0
        }
        
        access(contract) fun claimInterest(receiverID: UInt64, deposit: UFix64): UFix64 {
            let pending = self.calculatePendingInterest(receiverID: receiverID, deposit: deposit)
            
            if pending > 0.0 {
                let totalEarned = (deposit * self.accumulatedInterestPerShare) / self.PRECISION
                self.userClaimedAmount[receiverID] = totalEarned
            }
            
            return pending
        }
        
        access(contract) fun withdrawInterest(amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.interestVault.balance >= amount: "Insufficient interest vault balance"
            }
            return <- self.interestVault.withdraw(amount: amount)
        }
        
        access(contract) fun updateAfterBalanceChange(receiverID: UInt64, newDeposit: UFix64) {
            self.userClaimedAmount[receiverID] = (newDeposit * self.accumulatedInterestPerShare) / self.PRECISION
        }
    }
    
    // ========================================
    // Lottery Distributor
    // ========================================
    
    access(all) resource LotteryDistributor {
        access(self) var prizeVault: @{FungibleToken.Vault}
        access(self) var prizeHistory: {UInt64: UInt64}  // round -> receiverID
        access(self) var _prizeRound: UInt64
        access(all) var totalPrizesDistributed: UFix64
        
        access(all) fun getPrizeRound(): UInt64 {
            return self._prizeRound
        }
        
        access(contract) fun setPrizeRound(round: UInt64) {
            self._prizeRound = round
        }
        
        init(vaultType: Type) {
            self.prizeVault <- FlowToken.createEmptyVault(vaultType: vaultType)
            self.prizeHistory = {}
            self._prizeRound = 0
            self.totalPrizesDistributed = 0.0
        }
        
        access(contract) fun fundPrizePool(vault: @{FungibleToken.Vault}) {
            self.prizeVault.deposit(from: <- vault)
        }
        
        access(all) fun getPrizePoolBalance(): UFix64 {
            return self.prizeVault.balance
        }
        
        access(contract) fun awardPrize(receiverID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.prizeVault.balance >= amount: "Insufficient prize pool"
            }
            
            self.totalPrizesDistributed = self.totalPrizesDistributed + amount
            
            return <- self.prizeVault.withdraw(amount: amount)
        }
        
        access(all) fun getPrizeWinner(round: UInt64): UInt64? {
            return self.prizeHistory[round]
        }
    }
    
    // ========================================
    // Prize Draw Receipt
    // ========================================
    
    access(all) resource PrizeDrawReceipt {
        access(all) let prizeAmount: UFix64
        access(self) var request: @RandomConsumer.Request?
        
        init(prizeAmount: UFix64, request: @RandomConsumer.Request) {
            self.prizeAmount = prizeAmount
            self.request <- request
        }
        
        access(all) view fun getRequestBlock(): UInt64? {
            return self.request?.block
        }
        
        access(contract) fun popRequest(): @RandomConsumer.Request {
            let request <- self.request <- nil
            return <- request!
        }
    }
    
    // ========================================
    // Winner Selection Strategy
    // ========================================
    
    access(all) struct WinnerSelectionResult {
        access(all) let winners: [UInt64]  // receiverIDs
        access(all) let amounts: [UFix64]  // prize amounts (parallel arrays)
        
        init(winners: [UInt64], amounts: [UFix64]) {
            pre {
                winners.length == amounts.length: "Winners and amounts must have same length"
                winners.length > 0: "Must have at least one winner"
            }
            self.winners = winners
            self.amounts = amounts
        }
    }
    
    access(all) struct interface WinnerSelectionStrategy {
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult
        access(all) fun getStrategyName(): String
    }
    
    /// Weighted random selection - single winner (current behavior)
    access(all) struct WeightedSingleWinner: WinnerSelectionStrategy {
        init() {}
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            assert(receiverIDs.length > 0, message: "No depositors")
            
            if receiverIDs.length == 1 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount]
                )
            }
            
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                runningTotal = runningTotal + receiverDeposits[receiverID]!
                cumulativeSum.append(runningTotal)
            }
            
            let randomValue = UFix64(randomNumber % UInt64(runningTotal * 100000000.0)) / 100000000.0
            
            var winnerIndex = 0
            for i, cumSum in cumulativeSum {
                if randomValue < cumSum {
                    winnerIndex = i
                    break
                }
            }
            
            return WinnerSelectionResult(
                winners: [receiverIDs[winnerIndex]],
                amounts: [totalPrizeAmount]
            )
        }
        
        access(all) fun getStrategyName(): String {
            return "Weighted Single Winner"
        }
    }
    
    /// Multi-winner with split prizes (1st, 2nd, 3rd place, etc.)
    access(all) struct MultiWinnerSplit: WinnerSelectionStrategy {
        access(all) let winnerCount: Int
        access(all) let prizeSplits: [UFix64]  // e.g., [0.6, 0.3, 0.1] for 60%, 30%, 10%
        
        init(winnerCount: Int, prizeSplits: [UFix64]) {
            pre {
                winnerCount > 0 && winnerCount <= 10: "Winner count must be 1-10"
                prizeSplits.length == winnerCount: "Prize splits must match winner count"
            }
            
            // Validate all splits
            var total: UFix64 = 0.0
            for split in prizeSplits {
                assert(split >= 0.0 && split <= 1.0, message: "Each split must be between 0 and 1")
                total = total + split
            }
            
            assert(total == 1.0, message: "Prize splits must sum to 1.0")
            
            self.winnerCount = winnerCount
            self.prizeSplits = prizeSplits
        }
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            let depositorCount = receiverIDs.length
            
            assert(depositorCount > 0, message: "No depositors")
            assert(self.winnerCount <= depositorCount, message: "More winners than depositors")
            
            // If only one depositor, they win everything
            if depositorCount == 1 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount]
                )
            }
            
            // Build cumulative sum for weighted selection
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            var depositsList: [UFix64] = []
            
            for receiverID in receiverIDs {
                let deposit = receiverDeposits[receiverID]!
                depositsList.append(deposit)
                runningTotal = runningTotal + deposit
                cumulativeSum.append(runningTotal)
            }
            
            // Select winners using weighted random (without replacement)
            var selectedWinners: [UInt64] = []
            var selectedIndices: {Int: Bool} = {}
            var remainingDeposits = depositsList
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            // Use random number as seed, generate multiple selections
            var rng = randomNumber
            
            var winnerIndex = 0
            while winnerIndex < self.winnerCount && remainingIDs.length > 0 {
                // Generate random value for this selection
                let randomValue = UFix64(rng % UInt64(remainingTotal * 100000000.0)) / 100000000.0
                rng = rng / 100000000  // Use next part of random number
                
                // Find winner
                var selectedIdx = 0
                for i, cumSum in remainingCumSum {
                    if randomValue < cumSum {
                        selectedIdx = i
                        break
                    }
                }
                
                selectedWinners.append(remainingIDs[selectedIdx])
                selectedIndices[selectedIdx] = true
                
                // Remove winner from pool (for next selection)
                var newRemainingIDs: [UInt64] = []
                var newRemainingDeposits: [UFix64] = []
                var newCumSum: [UFix64] = []
                var newRunningTotal: UFix64 = 0.0
                
                var idx = 0
                while idx < remainingIDs.length {
                    if idx != selectedIdx {
                        newRemainingIDs.append(remainingIDs[idx])
                        newRemainingDeposits.append(remainingDeposits[idx])
                        newRunningTotal = newRunningTotal + remainingDeposits[idx]
                        newCumSum.append(newRunningTotal)
                    }
                    idx = idx + 1
                }
                
                remainingIDs = newRemainingIDs
                remainingDeposits = newRemainingDeposits
                remainingCumSum = newCumSum
                remainingTotal = newRunningTotal
                winnerIndex = winnerIndex + 1
            }
            
            // Calculate prize amounts based on splits
            var prizeAmounts: [UFix64] = []
            var idx = 0
            while idx < selectedWinners.length {
                let split = self.prizeSplits[idx]
                prizeAmounts.append(totalPrizeAmount * split)
                idx = idx + 1
            }
            
            return WinnerSelectionResult(
                winners: selectedWinners,
                amounts: prizeAmounts
            )
        }
        
        access(all) fun getStrategyName(): String {
            var name = "Multi-Winner (".concat(self.winnerCount.toString()).concat(" winners): ")
            var idx = 0
            while idx < self.prizeSplits.length {
                if idx > 0 {
                    name = name.concat(", ")
                }
                name = name.concat((self.prizeSplits[idx] * 100.0).toString()).concat("%")
                idx = idx + 1
            }
            return name
        }
    }
    
    // ========================================
    // Pool Configuration
    // ========================================
    
    access(all) struct PoolConfig {
        access(all) let assetType: Type
        access(all) var yieldSink: {DeFiActions.Sink}  // Made mutable for admin updates
        access(all) var yieldSource: {DeFiActions.Source}  // Made mutable for admin updates
        access(all) let priceOracle: {DeFiActions.PriceOracle}?
        access(all) let instantSwapper: {DeFiActions.Swapper}?
        access(all) let minimumDeposit: UFix64
        access(all) let drawIntervalSeconds: UFix64
        access(all) var distributionStrategy: {DistributionStrategy}  // Made mutable for strategy updates
        access(all) var winnerSelectionStrategy: {WinnerSelectionStrategy}  // Made mutable for strategy updates
        access(all) var winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?  // Made mutable for tracker updates
        
        init(
            assetType: Type,
            yieldSink: {DeFiActions.Sink},
            yieldSource: {DeFiActions.Source},
            priceOracle: {DeFiActions.PriceOracle}?,
            instantSwapper: {DeFiActions.Swapper}?,
            minimumDeposit: UFix64,
            drawIntervalSeconds: UFix64,
            distributionStrategy: {DistributionStrategy},
            winnerSelectionStrategy: {WinnerSelectionStrategy},
            winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        ) {
            self.assetType = assetType
            self.yieldSink = yieldSink
            self.yieldSource = yieldSource
            self.priceOracle = priceOracle
            self.instantSwapper = instantSwapper
            self.minimumDeposit = minimumDeposit
            self.drawIntervalSeconds = drawIntervalSeconds
            self.distributionStrategy = distributionStrategy
            self.winnerSelectionStrategy = winnerSelectionStrategy
            self.winnerTrackerCap = winnerTrackerCap
        }
        
        // Setters for strategy updates (contract-level access for Pool to update)
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.distributionStrategy = strategy
        }
        
        access(contract) fun setWinnerSelectionStrategy(strategy: {WinnerSelectionStrategy}) {
            self.winnerSelectionStrategy = strategy
        }
        
        access(contract) fun setWinnerTrackerCap(cap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?) {
            self.winnerTrackerCap = cap
        }
        
        access(contract) fun setYieldSink(sink: {DeFiActions.Sink}) {
            self.yieldSink = sink
        }
        
        access(contract) fun setYieldSource(source: {DeFiActions.Source}) {
            self.yieldSource = source
        }
    }
    
    // ========================================
    // Pool Resource
    // ========================================
    
    access(all) resource Pool {
        access(self) var config: PoolConfig  // Made mutable for strategy updates
        
        // Store the pool ID for tracking purposes
        access(self) var poolID: UInt64
        
        // Setter for pool ID (called once during creation)
        access(contract) fun setPoolID(id: UInt64) {
            self.poolID = id
        }
        
        // User tracking
        access(self) let receiverDeposits: {UInt64: UFix64}
        access(self) let receiverTotalClaimedSavings: {UInt64: UFix64}
        access(self) let receiverPrizes: {UInt64: UFix64}
        access(self) let registeredReceivers: {UInt64: Bool}
        
        // Pool state
        access(all) var totalDeposited: UFix64
        access(all) var totalStaked: UFix64
        access(all) var lastDrawTimestamp: UFix64
        
        // Modular components
        access(self) let rewardAggregator: @RewardAggregator
        access(self) let savingsDistributor: @SavingsDistributor
        access(self) let lotteryDistributor: @LotteryDistributor
        
        // Liquid vault and draw state
        access(self) var liquidVault: @{FungibleToken.Vault}
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        init(config: PoolConfig, initialVault: @{FungibleToken.Vault}) {
            pre {
                initialVault.getType() == config.assetType: "Vault type mismatch"
                initialVault.balance == 0.0: "Initial vault must be empty"
            }
            
            self.config = config
            self.poolID = 0  // Will be set by createPool after creation
            self.receiverDeposits = {}
            self.receiverTotalClaimedSavings = {}
            self.receiverPrizes = {}
            self.registeredReceivers = {}
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lastDrawTimestamp = getCurrentBlock().timestamp
            
            // Initialize modular components
            self.rewardAggregator <- create RewardAggregator(vaultType: config.assetType)
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            
            self.liquidVault <- initialVault
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            
            // Register reward sources
            let yieldSource <- create YieldRewardSource(
                yieldSource: config.yieldSource,
                priceOracle: config.priceOracle,
                assetType: config.assetType
            )
            self.rewardAggregator.registerSource(id: "yield", source: <- yieldSource)
            
            let contributionSource <- create DirectContributionSource(vaultType: config.assetType)
            self.rewardAggregator.registerSource(id: "contributions", source: <- contributionSource)
        }
        
        // ========================================
        // Core Functions
        // ========================================
        
        access(all) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            self.registeredReceivers[receiverID] = true
        }
        
        access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.getType() == self.config.assetType: "Invalid vault type"
                from.balance >= self.config.minimumDeposit: "Below minimum deposit"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let amount = from.balance
            let isFirstDeposit = (self.receiverDeposits[receiverID] ?? 0.0) == 0.0
            
            // Auto-claim pending interest before changing balance
            if !isFirstDeposit {
                let currentDeposit = self.receiverDeposits[receiverID]!
                let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                if pending > 0.0 {
                    let currentSavings = self.receiverTotalClaimedSavings[receiverID] ?? 0.0
                    self.receiverTotalClaimedSavings[receiverID] = currentSavings + pending
                    emit SavingsInterestClaimed(poolID: self.poolID, receiverID: receiverID, amount: pending)
                }
            }
            
            // Deposit to yield sink
            self.config.yieldSink.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy from
            
            // Update state
            let newDeposit = (self.receiverDeposits[receiverID] ?? 0.0) + amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited + amount
            self.totalStaked = self.totalStaked + amount
            
            // Initialize or update savings distributor
            if isFirstDeposit {
                self.savingsDistributor.initializeReceiver(receiverID: receiverID, deposit: amount)
            } else {
                self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            }
            
            // Update yield source staked amount
            let yieldSourceRef = self.rewardAggregator.borrowSource(id: "yield")! as! &YieldRewardSource
            yieldSourceRef.updateStaked(amount: self.totalStaked)
            
            emit Deposited(poolID: self.poolID, receiverID: receiverID, amount: amount)
        }
        
        access(all) fun instantWithdraw(amount: UFix64, minOut: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let receiverDeposit = self.receiverDeposits[receiverID] ?? 0.0
            assert(receiverDeposit >= amount, message: "Insufficient deposit")
            
            // Auto-claim pending interest
            let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: receiverDeposit)
            if pending > 0.0 {
                let currentSavings = self.receiverTotalClaimedSavings[receiverID] ?? 0.0
                self.receiverTotalClaimedSavings[receiverID] = currentSavings + pending
                emit SavingsInterestClaimed(poolID: self.uuid, receiverID: receiverID, amount: pending)
            }
            
            let swapper = self.config.instantSwapper ?? panic("Instant withdrawal not supported")
            
            // Withdraw and swap
            let yieldTokens <- self.config.yieldSource.withdrawAvailable(maxAmount: amount)
            let quote = swapper.quoteOut(forProvided: yieldTokens.balance, reverse: false)
            assert(quote.outAmount >= minOut, message: "Slippage too high")
            let swapped <- swapper.swap(quote: quote, inVault: <- yieldTokens)
            
            // Update state
            let newDeposit = receiverDeposit - amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited - amount
            self.totalStaked = self.totalStaked - amount
            
            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            
            let yieldSourceRef = self.rewardAggregator.borrowSource(id: "yield")! as! &YieldRewardSource
            yieldSourceRef.updateStaked(amount: self.totalStaked)
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, amount: swapped.balance)
            
            return <- swapped
        }
        
        // ========================================
        // Reward Processing
        // ========================================
        
        access(all) fun processRewards() {
            // Collect from all sources
            self.rewardAggregator.collectAllRewards()
            let totalRewards = self.rewardAggregator.getCollectedBalance()
            
            if totalRewards == 0.0 {
                return
            }
            
            // Calculate distribution
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: totalRewards)
            
            // Distribute to savings
            if plan.savingsAmount > 0.0 {
                let savingsVault <- self.rewardAggregator.withdrawCollected(amount: plan.savingsAmount)
                let interestPerShare = self.savingsDistributor.distributeInterest(
                    vault: <- savingsVault,
                    totalDeposited: self.totalDeposited
                )
                emit SavingsInterestDistributed(
                    poolID: self.poolID,
                    amount: plan.savingsAmount,
                    interestPerShare: interestPerShare
                )
            }
            
            // Fund lottery pool
            if plan.lotteryAmount > 0.0 {
                let lotteryVault <- self.rewardAggregator.withdrawCollected(amount: plan.lotteryAmount)
                self.lotteryDistributor.fundPrizePool(vault: <- lotteryVault)
            }
            
            // Handle treasury (for now, just add to lottery)
            if plan.treasuryAmount > 0.0 {
                let treasuryVault <- self.rewardAggregator.withdrawCollected(amount: plan.treasuryAmount)
                self.lotteryDistributor.fundPrizePool(vault: <- treasuryVault)
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: totalRewards,
                savingsAmount: plan.savingsAmount,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        access(all) fun contributeRewards(from: @{FungibleToken.Vault}, contributor: Address) {
            pre {
                from.getType() == self.config.assetType: "Invalid vault type"
            }
            
            let amount = from.balance
            let sourceRef = self.rewardAggregator.borrowSource(id: "contributions")! as! &DirectContributionSource
            sourceRef.contribute(from: <- from, contributor: contributor)
            
            emit RewardContributed(poolID: self.poolID, contributor: contributor, amount: amount)
        }
        
        // ========================================
        // Prize Draw
        // ========================================
        
        access(all) fun startDraw() {
            pre {
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            // Check if enough blocks have passed
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            // Process rewards first
            self.processRewards()
            
            let prizeAmount = self.lotteryDistributor.getPrizePoolBalance()
            assert(prizeAmount > 0.0, message: "No prize pool funds")
            
            // Request randomness
            let randomRequest <- self.randomConsumer.requestRandomness()
            let receipt <- create PrizeDrawReceipt(prizeAmount: prizeAmount, request: <- randomRequest)
            
            emit PrizeDrawCommitted(
                poolID: self.poolID,
                prizeAmount: prizeAmount,
                commitBlock: receipt.getRequestBlock()!
            )
            
            self.pendingDrawReceipt <-! receipt
            self.lastDrawTimestamp = getCurrentBlock().timestamp
        }
        
        access(all) fun completeDraw() {
            pre {
                self.pendingDrawReceipt != nil: "No draw in progress"
            }
            
            let receipt <- self.pendingDrawReceipt <- nil
            let unwrappedReceipt <- receipt!
            let totalPrizeAmount = unwrappedReceipt.prizeAmount
            
            // Get random number
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            
            // Select winners using strategy
            let selectionResult = self.config.winnerSelectionStrategy.selectWinners(
                randomNumber: randomNumber,
                receiverDeposits: self.receiverDeposits,
                totalPrizeAmount: totalPrizeAmount
            )
            
            let winners = selectionResult.winners
            let prizeAmounts = selectionResult.amounts
            
            // Increment round once for all winners in this draw
            let currentRound = self.lotteryDistributor.getPrizeRound() + 1
            self.lotteryDistributor.setPrizeRound(round: currentRound)
            
            // Award prizes to all winners
            var totalAwarded: UFix64 = 0.0
            
            var i = 0
            while i < winners.length {
                let winnerID = winners[i]
                let prizeAmount = prizeAmounts[i]
                
                // Award prize from lottery distributor
                let prizeVault <- self.lotteryDistributor.awardPrize(
                    receiverID: winnerID,
                    amount: prizeAmount
                )
                
                // Deposit directly into liquid vault (can't store resources in arrays)
                self.liquidVault.deposit(from: <- prizeVault)
                
                // Update prize tracking
                let currentPrizes = self.receiverPrizes[winnerID] ?? 0.0
                self.receiverPrizes[winnerID] = currentPrizes + prizeAmount
                
                totalAwarded = totalAwarded + prizeAmount
                i = i + 1
            }
            
            // Optional: Record winners in tracker (if configured)
            if let trackerCap = self.config.winnerTrackerCap {
                if let trackerRef = trackerCap.borrow() {
                    var idx = 0
                    while idx < winners.length {
                        trackerRef.recordWinner(
                            poolID: self.poolID,
                            round: currentRound,
                            winnerReceiverID: winners[idx],
                            amount: prizeAmounts[idx]
                        )
                        idx = idx + 1
                    }
                }
            }
            
            // Emit event (always use PrizesAwarded, even for single winner)
            emit PrizesAwarded(
                poolID: self.poolID,
                winners: winners,
                amounts: prizeAmounts,
                round: currentRound
            )
        }
        
        // ========================================
        // Claim Functions
        // ========================================
        
        access(all) fun claimSavingsInterest(receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let deposit = self.receiverDeposits[receiverID] ?? 0.0
            let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: deposit)
            
            if pending > 0.0 {
                let currentSavings = self.receiverTotalClaimedSavings[receiverID] ?? 0.0
                self.receiverTotalClaimedSavings[receiverID] = currentSavings + pending
                emit SavingsInterestClaimed(poolID: self.uuid, receiverID: receiverID, amount: pending)
            }
            
            return <- self.savingsDistributor.withdrawInterest(amount: pending)
        }
        
        access(all) fun withdrawPrize(receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let prizeAmount = self.receiverPrizes[receiverID] ?? 0.0
            assert(prizeAmount > 0.0, message: "No prizes to withdraw")
            assert(self.liquidVault.balance >= prizeAmount, message: "Insufficient liquid vault balance")
            
            // Withdraw from liquid vault
            let prizeVault <- self.liquidVault.withdraw(amount: prizeAmount)
            
            // Reset prize tracking
            self.receiverPrizes[receiverID] = 0.0
            
            return <- prizeVault
        }
        
        // Admin functions for strategy updates
        access(contract) fun getDistributionStrategyName(): String {
            return self.config.distributionStrategy.getStrategyName()
        }
        
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.config.setDistributionStrategy(strategy: strategy)
        }
        
        access(contract) fun getWinnerSelectionStrategyName(): String {
            return self.config.winnerSelectionStrategy.getStrategyName()
        }
        
        access(contract) fun setWinnerSelectionStrategy(strategy: {WinnerSelectionStrategy}) {
            self.config.setWinnerSelectionStrategy(strategy: strategy)
        }
        
        access(contract) fun getWinnerTrackerAddress(): Address? {
            if let cap = self.config.winnerTrackerCap {
                // Get the address from the capability's issuer
                // Note: Capabilities don't have a direct address property
                // We need to track this differently or return a flag
                return nil  // Capabilities don't have address, would need separate tracking
            }
            return nil
        }
        
        // Public getter to check if tracker is configured
        access(all) fun hasWinnerTracker(): Bool {
            return self.config.winnerTrackerCap != nil
        }
        
        access(contract) fun setWinnerTrackerCap(cap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?) {
            self.config.setWinnerTrackerCap(cap: cap)
        }
        
        access(contract) fun setYieldSink(sink: {DeFiActions.Sink}) {
            self.config.setYieldSink(sink: sink)
        }
        
        access(contract) fun setYieldSource(source: {DeFiActions.Source}) {
            self.config.setYieldSource(source: source)
            // Update the YieldRewardSource resource with the new source
            if let yieldSourceRef = self.rewardAggregator.borrowSource(id: "yield") as? &YieldRewardSource {
                // Note: YieldRewardSource.yieldSource is immutable, so we need to recreate it
                // Remove old source and create new one
                self.rewardAggregator.removeSource(id: "yield")
                let newYieldSource <- create YieldRewardSource(
                    yieldSource: source,
                    priceOracle: self.config.priceOracle,
                    assetType: self.config.assetType
                )
                self.rewardAggregator.registerSource(id: "yield", source: <- newYieldSource)
                // Restore the staked amount
                if let updatedYieldSourceRef = self.rewardAggregator.borrowSource(id: "yield") as? &YieldRewardSource {
                    updatedYieldSourceRef.updateStaked(amount: self.totalStaked)
                }
            }
        }
        
        // Admin functions for reward source management
        access(contract) fun registerRewardSource(id: String, source: @{RewardSource}) {
            self.rewardAggregator.registerSource(id: id, source: <- source)
        }
        
        access(contract) fun removeRewardSource(id: String) {
            self.rewardAggregator.removeSource(id: id)
        }
        
        access(contract) fun getRewardSourceName(id: String): String? {
            if let sourceRef = self.rewardAggregator.borrowSource(id: id) {
                return sourceRef.getSourceName()
            }
            return nil
        }
        
        // ========================================
        // Getters
        // ========================================
        
        access(all) fun canDrawNow(): Bool {
            return (getCurrentBlock().timestamp - self.lastDrawTimestamp) >= self.config.drawIntervalSeconds
        }
        
        access(all) fun getReceiverDeposit(receiverID: UInt64): UFix64 {
            return self.receiverDeposits[receiverID] ?? 0.0
        }
        
        access(all) fun getReceiverPrizes(receiverID: UInt64): UFix64 {
            return self.receiverPrizes[receiverID] ?? 0.0
        }
        
        access(all) fun getReceiverTotalClaimedSavings(receiverID: UInt64): UFix64 {
            return self.receiverTotalClaimedSavings[receiverID] ?? 0.0
        }
        
        access(all) fun getPendingSavingsInterest(receiverID: UInt64): UFix64 {
            let deposit = self.receiverDeposits[receiverID] ?? 0.0
            return self.savingsDistributor.calculatePendingInterest(receiverID: receiverID, deposit: deposit)
        }
        
        access(all) fun isReceiverRegistered(receiverID: UInt64): Bool {
            return self.registeredReceivers[receiverID] == true
        }
        
        access(all) fun isDrawInProgress(): Bool {
            return self.pendingDrawReceipt != nil
        }
        
        access(all) fun getConfig(): PoolConfig {
            return self.config
        }
        
        // ========================================
        // Admin Functions
        // ========================================
        
    }
    
    // ========================================
    // Pool Position Collection
    // ========================================
    
    access(all) struct PoolBalance {
        access(all) let deposits: UFix64
        access(all) let prizes: UFix64
        access(all) let totalClaimedSavings: UFix64
        access(all) let pendingSavings: UFix64
        access(all) let totalBalance: UFix64
        
        init(deposits: UFix64, prizes: UFix64, totalClaimedSavings: UFix64, pendingSavings: UFix64) {
            self.deposits = deposits
            self.prizes = prizes
            self.totalClaimedSavings = totalClaimedSavings
            self.pendingSavings = pendingSavings
            // totalBalance = invested amount (deposits) + earned but not claimed (pendingSavings)
            // Does NOT include: prizes (won but not invested) or totalClaimedSavings (already withdrawn)
            self.totalBalance = deposits + pendingSavings
        }
    }
    
    access(all) resource interface PoolPositionCollectionPublic {
        access(all) fun getRegisteredPoolIDs(): [UInt64]
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault})
        access(all) fun instantWithdraw(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault}
        access(all) fun claimSavingsInterest(poolID: UInt64): @{FungibleToken.Vault}
        access(all) fun withdrawPrize(poolID: UInt64): @{FungibleToken.Vault}
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance
    }
    
    access(all) resource PoolPositionCollection: PoolPositionCollectionPublic {
        access(self) let registeredPools: {UInt64: Bool}
        
        init() {
            self.registeredPools = {}
        }
        
        access(self) fun registerWithPool(poolID: UInt64) {
            pre {
                self.registeredPools[poolID] == nil: "Already registered"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.registerReceiver(receiverID: self.uuid)
            self.registeredPools[poolID] = true
        }
        
        access(all) fun getRegisteredPoolIDs(): [UInt64] {
            return self.registeredPools.keys
        }
        
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool {
            return self.registeredPools[poolID] == true
        }
        
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault}) {
            if self.registeredPools[poolID] == nil {
                self.registerWithPool(poolID: poolID)
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.deposit(from: <- from, receiverID: self.uuid)
        }
        
        access(all) fun instantWithdraw(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.instantWithdraw(amount: amount, minOut: minOut, receiverID: self.uuid)
        }
        
        access(all) fun claimSavingsInterest(poolID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.claimSavingsInterest(receiverID: self.uuid)
        }
        
        access(all) fun withdrawPrize(poolID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.withdrawPrize(receiverID: self.uuid)
        }
        
        access(all) fun contributeRewards(poolID: UInt64, from: @{FungibleToken.Vault}, contributor: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.contributeRewards(from: <- from, contributor: contributor)
        }
        
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            if self.registeredPools[poolID] == nil {
                return PoolBalance(deposits: 0.0, prizes: 0.0, totalClaimedSavings: 0.0, pendingSavings: 0.0)
            }
            
            let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            if poolRef == nil {
                return PoolBalance(deposits: 0.0, prizes: 0.0, totalClaimedSavings: 0.0, pendingSavings: 0.0)
            }
            
            return PoolBalance(
                deposits: poolRef!.getReceiverDeposit(receiverID: self.uuid),
                prizes: poolRef!.getReceiverPrizes(receiverID: self.uuid),
                totalClaimedSavings: poolRef!.getReceiverTotalClaimedSavings(receiverID: self.uuid),
                pendingSavings: poolRef!.getPendingSavingsInterest(receiverID: self.uuid)
            )
        }
    }
    
    // ========================================
    // Contract Functions
    // ========================================
    
    access(all) entitlement PoolAccess
    
    access(all) fun createPool(config: PoolConfig): UInt64 {
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let pool <- create Pool(config: config, initialVault: <- emptyVault)
        
        let poolID = self.nextPoolID
        self.nextPoolID = self.nextPoolID + 1
        
        // Set the pool ID in the pool resource
        pool.setPoolID(id: poolID)
        
        emit PoolCreated(
            poolID: poolID,
            assetType: config.assetType.identifier,
            strategy: config.distributionStrategy.getStrategyName()
        )
        
        self.pools[poolID] <-! pool
        return poolID
    }
    
    access(all) view fun borrowPool(poolID: UInt64): &Pool? {
        return &self.pools[poolID]
    }
    
    access(all) fun borrowPoolAuth(poolID: UInt64): auth(PoolAccess) &Pool? {
        return &self.pools[poolID]
    }
    
    access(all) view fun getAllPoolIDs(): [UInt64] {
        return self.pools.keys
    }
    
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    // ========================================
    // Admin Functions
    // ========================================
    
    /// Create and return the initial admin resource
    /// This should be called once after contract deployment
    /// The returned resource should be stored in the admin's account storage
    access(all) fun createAdmin(): @Admin {
        return <- create Admin()
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.PoolPositionCollectionStoragePath = /storage/PrizeVaultModularCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeVaultModularCollection
        
        self.AdminStoragePath = /storage/PrizeVaultModularAdmin
        self.AdminPublicPath = /public/PrizeVaultModularAdmin
        
        self.pools <- {}
        self.nextPoolID = 0
    }
}

