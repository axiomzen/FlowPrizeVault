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
    
    // Storage Paths
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    // Events
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event RewardsCollected(poolID: UInt64, sourceID: String, amount: UFix64)
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    access(all) event RewardContributed(poolID: UInt64, contributor: Address, amount: UFix64)
    
    access(all) event SavingsInterestDistributed(poolID: UInt64, amount: UFix64, interestPerShare: UFix64)
    access(all) event SavingsInterestCompounded(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    access(all) event PrizeWithdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, updatedBy: Address)
    access(all) event DrawIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, updatedBy: Address)
    access(all) event RewardSourceRegistered(poolID: UInt64, sourceID: String, sourceName: String, updatedBy: Address)
    access(all) event RewardSourceRemoved(poolID: UInt64, sourceID: String, updatedBy: Address)
    access(all) event PoolCreatedByAdmin(poolID: UInt64, assetType: String, strategy: String, createdBy: Address)
    access(all) event MaxPoolsUpdated(oldLimit: UInt64, newLimit: UInt64)
    
    access(all) event PoolPaused(poolID: UInt64, pausedBy: Address, reason: String)
    access(all) event PoolUnpaused(poolID: UInt64, unpausedBy: Address)
    access(all) event TreasuryFunded(poolID: UInt64, amount: UFix64, source: String)
    access(all) event TreasuryWithdrawn(poolID: UInt64, withdrawnBy: Address, amount: UFix64, purpose: String, remainingBalance: UFix64)
    
    // Pool Storage
    access(self) var pools: @{UInt64: Pool}
    access(self) var nextPoolID: UInt64
    access(self) var maxPools: UInt64
    
    // Admin Resource - must be held to perform admin operations
    access(all) resource Admin {
        init() {}
        
        // Update pool distribution strategy
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
        
        // Update pool winner selection strategy
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
        
        // Update pool winner tracker
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
        
        // Update pool draw interval
        access(all) fun updatePoolDrawInterval(
            poolID: UInt64,
            newInterval: UFix64,
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let oldInterval = poolRef.getConfig().drawIntervalSeconds
            poolRef.setDrawIntervalSeconds(interval: newInterval)
            
            emit DrawIntervalUpdated(
                poolID: poolID,
                oldInterval: oldInterval,
                newInterval: newInterval,
                updatedBy: updatedBy
            )
        }
        
        // Note: Yield connector is immutable per pool for security
        // To use different yield protocol, create a new pool
        
        // Create new pool
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
        
        access(all) fun processPoolRewards(poolID: UInt64) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.processRewards()
        }
        
        access(all) fun updateMaxPools(newLimit: UInt64) {
            pre {
                newLimit >= UInt64(PrizeVaultModular.pools.keys.length): "New limit cannot be less than current pool count"
            }
            let oldLimit = PrizeVaultModular.maxPools
            PrizeVaultModular.maxPools = newLimit
            emit MaxPoolsUpdated(oldLimit: oldLimit, newLimit: newLimit)
        }
        
        // Circuit Breaker - pause critical operations (not withdrawals)
        access(all) fun pausePool(poolID: UInt64, pausedBy: Address, reason: String) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.pause()
            
            emit PoolPaused(
                poolID: poolID,
                pausedBy: pausedBy,
                reason: reason
            )
        }
        
        access(all) fun unpausePool(poolID: UInt64, unpausedBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.unpause()
            
            emit PoolUnpaused(
                poolID: poolID,
                unpausedBy: unpausedBy
            )
        }
        
        // Treasury withdrawal - all withdrawals recorded on-chain
        access(all) fun withdrawPoolTreasury(
            poolID: UInt64,
            amount: UFix64,
            purpose: String,
            withdrawnBy: Address
        ): @{FungibleToken.Vault} {
            pre {
                purpose.length > 0: "Purpose must be specified for treasury withdrawal"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let treasuryVault <- poolRef.withdrawTreasury(
                amount: amount,
                withdrawnBy: withdrawnBy,
                purpose: purpose
            )
            
            emit TreasuryWithdrawn(
                poolID: poolID,
                withdrawnBy: withdrawnBy,
                amount: amount,
                purpose: purpose,
                remainingBalance: poolRef.getTreasuryBalance()
            )
            
            return <- treasuryVault
        }
        
        // Admin transfer: Use two-party transaction (load from old account, save to new)
        // This ensures only ONE admin resource exists and both parties consent
    }
    
    access(all) let AdminStoragePath: StoragePath
    access(all) let AdminPublicPath: PublicPath
    
    // Distribution Strategy
    
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
    
    // Reward Sources
    access(all) resource interface RewardSource {
        access(all) fun getAvailableRewards(): UFix64
        access(all) fun collectRewards(): @{FungibleToken.Vault}
        access(all) fun getSourceName(): String
    }
    
    // Yield handled directly in Pool via yieldConnector
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
    
    // Reward Aggregator
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
            return &self.sources[id]
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
        
        access(all) fun getSourceIDs(): [String] {
            return self.sources.keys
        }
        
        access(all) fun getAvailableFromSource(id: String): UFix64 {
            let sourceRef = &self.sources[id] as &{RewardSource}?
            return sourceRef?.getAvailableRewards() ?? 0.0
        }
        
        access(all) fun getSourceName(id: String): String? {
            let sourceRef = &self.sources[id] as &{RewardSource}?
            return sourceRef?.getSourceName()
        }
    }
    
    // Savings Distributor - O(1) time-weighted distribution
    access(all) resource SavingsDistributor {
        access(self) let PRECISION: UFix64
        access(self) var accumulatedInterestPerShare: UFix64
        access(self) let userClaimedAmount: {UInt64: UFix64}
        access(self) var interestVault: @{FungibleToken.Vault}
        access(all) var totalDistributed: UFix64
        
        init(vaultType: Type) {
            // PRECISION = 1e8 provides better accuracy while maintaining UFix64 overflow safety
            // Max safe amount = UFix64.max / PRECISION ≈ 180 billion tokens
            self.PRECISION = 100000000.0
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
            
            // Overflow protection: Check multiplication and accumulation safety
            let maxSafeAmount = UFix64.max / self.PRECISION
            assert(amount <= maxSafeAmount, message: "Reward amount too large - would cause overflow")
            
            let interestPerShare = (amount * self.PRECISION) / totalDeposited
            
            let overflowThreshold = UFix64.max * 0.8
            assert(
                self.accumulatedInterestPerShare <= overflowThreshold - interestPerShare,
                message: "Interest accumulation approaching overflow - pool must be migrated"
            )
            
            self.accumulatedInterestPerShare = self.accumulatedInterestPerShare + interestPerShare
            
            self.interestVault.deposit(from: <- vault)
            self.totalDistributed = self.totalDistributed + amount
            
            return interestPerShare
        }
        
        /// Distribute interest and reinvest into yield source to continue generating yield
        access(contract) fun distributeInterestAndReinvest(
            vault: @{FungibleToken.Vault}, 
            totalDeposited: UFix64,
            yieldSink: &{DeFiActions.Sink}
        ): UFix64 {
            let amount = vault.balance
            
            if amount == 0.0 || totalDeposited == 0.0 {
                // Even if zero, reinvest to keep vault clean
                yieldSink.depositCapacity(from: &vault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                destroy vault
                return 0.0
            }
            
            // Overflow protection: Check multiplication and accumulation safety
            let maxSafeAmount = UFix64.max / self.PRECISION
            assert(amount <= maxSafeAmount, message: "Reward amount too large - would cause overflow")
            
            let interestPerShare = (amount * self.PRECISION) / totalDeposited
            
            let overflowThreshold = UFix64.max * 0.8
            assert(
                self.accumulatedInterestPerShare <= overflowThreshold - interestPerShare,
                message: "Interest accumulation approaching overflow - pool must be migrated"
            )
            
            self.accumulatedInterestPerShare = self.accumulatedInterestPerShare + interestPerShare
            
            // Reinvest into yield source instead of storing in interestVault
            yieldSink.depositCapacity(from: &vault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy vault
            self.totalDistributed = self.totalDistributed + amount
            
            return interestPerShare
        }
        
        access(contract) fun initializeReceiver(receiverID: UInt64, deposit: UFix64) {
            // Initialize or re-initialize to prevent claiming past interest
            self.userClaimedAmount[receiverID] = (deposit * self.accumulatedInterestPerShare) / self.PRECISION
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
        
        /// Withdraw interest, using yield source if interestVault is insufficient (for reinvested savings)
        access(contract) fun withdrawInterestWithYieldSource(
            amount: UFix64,
            yieldSource: auth(FungibleToken.Withdraw) &{DeFiActions.Source}
        ): @{FungibleToken.Vault} {
            if amount == 0.0 {
                // Get vault type from interestVault
                let vaultType = self.interestVault.getType()
                return <- FlowToken.createEmptyVault(vaultType: vaultType)
            }
            
            var remaining = amount
            // Get vault type from interestVault to create result vault
            let vaultType = self.interestVault.getType()
            var resultVault <- FlowToken.createEmptyVault(vaultType: vaultType)
            
            // First, try to withdraw from interestVault (for any non-reinvested interest)
            if self.interestVault.balance > 0.0 {
                let fromVault = remaining < self.interestVault.balance ? remaining : self.interestVault.balance
                resultVault.deposit(from: <- self.interestVault.withdraw(amount: fromVault))
                remaining = remaining - fromVault
            }
            
            // If still need more, withdraw from yield source (reinvested savings)
            if remaining > 0.0 {
                let availableFromYield = yieldSource.minimumAvailable()
                let fromYield = remaining < availableFromYield ? remaining : availableFromYield
                if fromYield > 0.0 {
                    resultVault.deposit(from: <- yieldSource.withdrawAvailable(maxAmount: fromYield))
                    remaining = remaining - fromYield
                }
            }
            
            assert(remaining == 0.0, message: "Insufficient interest available (vault + yield source)")
            return <- resultVault
        }
        
        access(contract) fun updateAfterBalanceChange(receiverID: UInt64, newDeposit: UFix64) {
            self.userClaimedAmount[receiverID] = (newDeposit * self.accumulatedInterestPerShare) / self.PRECISION
        }
        
        access(all) fun getInterestVaultBalance(): UFix64 {
            return self.interestVault.balance
        }
        
        access(all) fun getTotalDistributed(): UFix64 {
            return self.totalDistributed
        }
    }
    
    // Lottery Distributor
    access(all) resource LotteryDistributor {
        access(self) var prizeVault: @{FungibleToken.Vault}
        access(self) var prizeHistory: {UInt64: UInt64}
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
        
        access(contract) fun awardPrize(receiverID: UInt64, amount: UFix64, yieldSource: auth(FungibleToken.Withdraw) &{DeFiActions.Source}?): @{FungibleToken.Vault} {
            self.totalPrizesDistributed = self.totalPrizesDistributed + amount
            
            var result <- FlowToken.createEmptyVault(vaultType: self.prizeVault.getType())
            
            // If yield source is provided (lottery is reinvested), try to withdraw from it first
            if yieldSource != nil {
                let available = yieldSource!.minimumAvailable()
                if available >= amount {
                    result.deposit(from: <- yieldSource!.withdrawAvailable(maxAmount: amount))
                    return <- result
                } else if available > 0.0 {
                    // Partial withdrawal from yield source
                    result.deposit(from: <- yieldSource!.withdrawAvailable(maxAmount: available))
                }
            }
            
            // Withdraw remainder from internal vault
            if result.balance < amount {
                let remaining = amount - result.balance
                assert(self.prizeVault.balance >= remaining, message: "Insufficient prize pool")
                result.deposit(from: <- self.prizeVault.withdraw(amount: remaining))
            }
            
            return <- result
        }
        
        access(all) fun getPrizeWinner(round: UInt64): UInt64? {
            return self.prizeHistory[round]
        }
    }
    
    // Treasury Distributor
    access(all) resource TreasuryDistributor {
        access(self) var treasuryVault: @{FungibleToken.Vault}
        access(all) var totalCollected: UFix64
        access(all) var totalWithdrawn: UFix64
        access(self) var withdrawalHistory: [{String: AnyStruct}]
        
        init(vaultType: Type) {
            self.treasuryVault <- FlowToken.createEmptyVault(vaultType: vaultType)
            self.totalCollected = 0.0
            self.totalWithdrawn = 0.0
            self.withdrawalHistory = []
        }
        
        access(contract) fun deposit(vault: @{FungibleToken.Vault}) {
            let amount = vault.balance
            self.totalCollected = self.totalCollected + amount
            self.treasuryVault.deposit(from: <- vault)
        }
        
        access(all) fun getBalance(): UFix64 {
            return self.treasuryVault.balance
        }
        
        access(all) fun getTotalCollected(): UFix64 {
            return self.totalCollected
        }
        
        access(all) fun getTotalWithdrawn(): UFix64 {
            return self.totalWithdrawn
        }
        
        access(all) fun getWithdrawalHistory(): [{String: AnyStruct}] {
            return self.withdrawalHistory
        }
        
        access(contract) fun withdraw(amount: UFix64, withdrawnBy: Address, purpose: String): @{FungibleToken.Vault} {
            pre {
                self.treasuryVault.balance >= amount: "Insufficient treasury balance"
                amount > 0.0: "Withdrawal amount must be positive"
                purpose.length > 0: "Purpose must be specified"
            }
            
            self.totalWithdrawn = self.totalWithdrawn + amount
            
            self.withdrawalHistory.append({
                "address": withdrawnBy,
                "amount": amount,
                "timestamp": getCurrentBlock().timestamp,
                "purpose": purpose
            })
            
            return <- self.treasuryVault.withdraw(amount: amount)
        }
    }
    
    // Prize Draw Receipt
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
    
    // Winner Selection Strategy
    access(all) struct WinnerSelectionResult {
        access(all) let winners: [UInt64]
        access(all) let amounts: [UFix64]
        
        init(winners: [UInt64], amounts: [UFix64]) {
            pre {
                winners.length == amounts.length: "Winners and amounts must have same length"
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
    
    // Weighted random selection - single winner
    access(all) struct WeightedSingleWinner: WinnerSelectionStrategy {
        init() {}
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            
            if receiverIDs.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [])
            }
            
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
    
    // Multi-winner with split prizes
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
        
        // Generate independent random numbers using SHA3_256 hashing
        access(self) fun generateRandomFromSeed(seed: UInt64, iteration: UInt64): UInt64 {
            let seedBytes = seed.toBigEndianBytes()
            let iterBytes = iteration.toBigEndianBytes()
            
            let combined = seedBytes.concat(iterBytes)
            let hash = HashAlgorithm.SHA3_256.hash(combined)
            var result: UInt64 = 0
            var i = 0
            while i < 8 {
                result = (result << 8) | UInt64(hash[i])
                i = i + 1
            }
            
            return result
        }
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            let depositorCount = receiverIDs.length
            
            if depositorCount == 0 {
                return WinnerSelectionResult(winners: [], amounts: [])
            }
            
            assert(self.winnerCount <= depositorCount, message: "More winners than depositors")
            
            if depositorCount == 1 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount]
                )
            }
            
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            var depositsList: [UFix64] = []
            
            for receiverID in receiverIDs {
                let deposit = receiverDeposits[receiverID]!
                depositsList.append(deposit)
                runningTotal = runningTotal + deposit
                cumulativeSum.append(runningTotal)
            }
            
            var selectedWinners: [UInt64] = []
            var selectedIndices: {Int: Bool} = {}
            var remainingDeposits = depositsList
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            var winnerIndex = 0
            while winnerIndex < self.winnerCount && remainingIDs.length > 0 {
                let rng = self.generateRandomFromSeed(seed: randomNumber, iteration: UInt64(winnerIndex))
                let randomValue = UFix64(rng % UInt64(remainingTotal * 100000000.0)) / 100000000.0
                
                var selectedIdx = 0
                for i, cumSum in remainingCumSum {
                    if randomValue < cumSum {
                        selectedIdx = i
                        break
                    }
                }
                
                selectedWinners.append(remainingIDs[selectedIdx])
                selectedIndices[selectedIdx] = true
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
            
            var prizeAmounts: [UFix64] = []
            var calculatedSum: UFix64 = 0.0
            var idx = 0
            
            while idx < selectedWinners.length - 1 {
                let split = self.prizeSplits[idx]
                let amount = totalPrizeAmount * split
                prizeAmounts.append(amount)
                calculatedSum = calculatedSum + amount
                idx = idx + 1
            }
            
            // Last prize gets remainder to ensure exact sum
            let lastPrize = totalPrizeAmount - calculatedSum
            prizeAmounts.append(lastPrize)
            
            var finalSum: UFix64 = 0.0
            for amount in prizeAmounts {
                finalSum = finalSum + amount
            }
            assert(finalSum == totalPrizeAmount, message: "Prize amounts must sum to total prize pool")
            
            let expectedLast = totalPrizeAmount * self.prizeSplits[selectedWinners.length - 1]
            let deviation = lastPrize > expectedLast ? lastPrize - expectedLast : expectedLast - lastPrize
            let maxDeviation = totalPrizeAmount * 0.01 // 1% tolerance
            assert(deviation <= maxDeviation, message: "Last prize deviation too large - check splits")
            
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
    
    // Pool Configuration
    access(all) struct PoolConfig {
        access(all) let assetType: Type
        access(all) let yieldConnector: {DeFiActions.Sink, DeFiActions.Source}
        access(all) let priceOracle: {DeFiActions.PriceOracle}?
        access(all) let instantSwapper: {DeFiActions.Swapper}?
        access(all) let minimumDeposit: UFix64
        access(all) var drawIntervalSeconds: UFix64
        access(all) var distributionStrategy: {DistributionStrategy}
        access(all) var winnerSelectionStrategy: {WinnerSelectionStrategy}
        access(all) var winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        
        init(
            assetType: Type,
            yieldConnector: {DeFiActions.Sink, DeFiActions.Source},
            priceOracle: {DeFiActions.PriceOracle}?,
            instantSwapper: {DeFiActions.Swapper}?,
            minimumDeposit: UFix64,
            drawIntervalSeconds: UFix64,
            distributionStrategy: {DistributionStrategy},
            winnerSelectionStrategy: {WinnerSelectionStrategy},
            winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        ) {
            self.assetType = assetType
            self.yieldConnector = yieldConnector
            self.priceOracle = priceOracle
            self.instantSwapper = instantSwapper
            self.minimumDeposit = minimumDeposit
            self.drawIntervalSeconds = drawIntervalSeconds
            self.distributionStrategy = distributionStrategy
            self.winnerSelectionStrategy = winnerSelectionStrategy
            self.winnerTrackerCap = winnerTrackerCap
        }
        
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.distributionStrategy = strategy
        }
        
        access(contract) fun setWinnerSelectionStrategy(strategy: {WinnerSelectionStrategy}) {
            self.winnerSelectionStrategy = strategy
        }
        
        access(contract) fun setWinnerTrackerCap(cap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?) {
            self.winnerTrackerCap = cap
        }
        
        access(contract) fun setDrawIntervalSeconds(interval: UFix64) {
            pre {
                interval >= 3600.0: "Draw interval must be at least 1 hour (3600 seconds)"
            }
            self.drawIntervalSeconds = interval
        }
    }
    
    // Pool Resource
    access(all) resource Pool {
        access(self) var config: PoolConfig
        access(self) var poolID: UInt64
        access(self) var paused: Bool
        
        access(contract) fun setPoolID(id: UInt64) {
            self.poolID = id
        }
        
        // User tracking
        access(self) let receiverDeposits: {UInt64: UFix64}
        access(self) let receiverTotalEarnedSavings: {UInt64: UFix64}
        access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
        access(self) let receiverPrizes: {UInt64: UFix64}
        access(self) let registeredReceivers: {UInt64: Bool}
        access(all) var totalDeposited: UFix64
        access(all) var totalStaked: UFix64
        access(all) var lotteryStaked: UFix64
        access(all) var lastDrawTimestamp: UFix64
        access(self) let rewardAggregator: @RewardAggregator
        access(self) let savingsDistributor: @SavingsDistributor
        access(self) let lotteryDistributor: @LotteryDistributor
        access(self) let treasuryDistributor: @TreasuryDistributor
        
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
            self.poolID = 0
            self.paused = false
            self.receiverDeposits = {}
            self.receiverTotalEarnedSavings = {}
            self.receiverTotalEarnedPrizes = {}
            self.receiverPrizes = {}
            self.registeredReceivers = {}
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lotteryStaked = 0.0
            self.lastDrawTimestamp = 0.0
            
            // Initialize modular components
            self.rewardAggregator <- create RewardAggregator(vaultType: config.assetType)
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            self.treasuryDistributor <- create TreasuryDistributor(vaultType: config.assetType)
            
            self.liquidVault <- initialVault
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            
            let contributionSource <- create DirectContributionSource(vaultType: config.assetType)
            self.rewardAggregator.registerSource(id: "contributions", source: <- contributionSource)
        }
        
        access(all) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            self.registeredReceivers[receiverID] = true
        }
        
        access(all) view fun isPaused(): Bool {
            return self.paused
        }
        
        access(contract) fun pause() {
            pre {
                !self.paused: "Pool is already paused"
            }
            self.paused = true
        }
        
        access(contract) fun unpause() {
            pre {
                self.paused: "Pool is not paused"
            }
            self.paused = false
        }
        
        access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                !self.paused: "Pool is paused - deposits are temporarily disabled"
                from.getType() == self.config.assetType: "Invalid vault type"
                from.balance >= self.config.minimumDeposit: "Below minimum deposit"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let amount = from.balance
            let isFirstDeposit = (self.receiverDeposits[receiverID] ?? 0.0) == 0.0
            if !isFirstDeposit {
                let currentDeposit = self.receiverDeposits[receiverID]!
                let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                if pending > 0.0 {
                    let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                    self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                    emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
                }
            }
            
            let newDeposit = (self.receiverDeposits[receiverID] ?? 0.0) + amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited + amount
            self.totalStaked = self.totalStaked + amount
            
            if isFirstDeposit {
                self.savingsDistributor.initializeReceiver(receiverID: receiverID, deposit: amount)
            } else {
                self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            }
            self.config.yieldConnector.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy from
            emit Deposited(poolID: self.poolID, receiverID: receiverID, amount: amount)
        }
        
        access(all) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let receiverDeposit = self.receiverDeposits[receiverID] ?? 0.0
            assert(receiverDeposit >= amount, message: "Insufficient deposit. You have ".concat(receiverDeposit.toString()).concat(" but trying to withdraw ").concat(amount.toString()))
            
            // Compound any pending savings first
            let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: receiverDeposit)
            if pending > 0.0 {
                let newDepositWithPending = receiverDeposit + pending
                self.receiverDeposits[receiverID] = newDepositWithPending
                self.totalDeposited = self.totalDeposited + pending
                // totalStaked already includes this from processRewards
                
                self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDepositWithPending)
                
                let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
            }
            
            // Update deposit after compounding
            let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
            let newDeposit = currentDeposit - amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited - amount
            self.totalStaked = self.totalStaked - amount
            
            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            
            // Withdraw from yield source
            let withdrawnVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
            assert(withdrawnVault.balance >= amount, message: "Insufficient yield source balance")
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, amount: withdrawnVault.balance)
            return <- withdrawnVault
        }
        
        access(all) fun instantWithdraw(amount: UFix64, minOut: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let receiverDeposit = self.receiverDeposits[receiverID] ?? 0.0
            assert(receiverDeposit >= amount, message: "Insufficient deposit")
            
            let swapper = self.config.instantSwapper ?? panic("Instant withdrawal not supported")
            let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: receiverDeposit)
            if pending > 0.0 {
                let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
            }
            
            let newDeposit = receiverDeposit - amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited - amount
            self.totalStaked = self.totalStaked - amount
            
            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            let yieldTokens <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
            let quote = swapper.quoteOut(forProvided: yieldTokens.balance, reverse: false)
            assert(quote.outAmount >= minOut, message: "Slippage too high")
            let swapped <- swapper.swap(quote: quote, inVault: <- yieldTokens)
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, amount: swapped.balance)
            return <- swapped
        }
        
        access(all) fun processRewards() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            var availableYield: UFix64 = 0.0
            
            if let oracle = self.config.priceOracle {
                if let rate = oracle.price(ofToken: self.config.assetType) {
                    let totalValue = yieldBalance * rate
                    availableYield = totalValue > self.totalStaked ? totalValue - self.totalStaked : 0.0
                }
            } else {
                availableYield = yieldBalance > self.totalStaked ? yieldBalance - self.totalStaked : 0.0
            }
            
            var yieldRewards: @{FungibleToken.Vault}? <- nil
            if availableYield > 0.0 {
                yieldRewards <-! self.config.yieldConnector.withdrawAvailable(maxAmount: availableYield)
            }
            
            self.rewardAggregator.collectAllRewards()
            let otherRewards = self.rewardAggregator.getCollectedBalance()
            let yieldAmount = yieldRewards?.balance ?? 0.0
            let totalRewards = yieldAmount + otherRewards
            if totalRewards == 0.0 {
                destroy yieldRewards
                return
            }
            
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: totalRewards)
            if plan.savingsAmount > 0.0 {
                var savingsVault <- FlowToken.createEmptyVault(vaultType: self.config.assetType)
                if yieldRewards != nil && yieldRewards?.balance! > 0.0 {
                    let yieldBalance = yieldRewards?.balance!
                    let fromYield = plan.savingsAmount < yieldBalance ? plan.savingsAmount : yieldBalance
                    let yieldRef = &yieldRewards as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
                    savingsVault.deposit(from: <- yieldRef!.withdraw(amount: fromYield))
                }
                
                if savingsVault.balance < plan.savingsAmount {
                    let remaining = plan.savingsAmount - savingsVault.balance
                    savingsVault.deposit(from: <- self.rewardAggregator.withdrawCollected(amount: remaining))
                }
                
                // Always reinvest savings back into yield source to continue generating yield
                let interestPerShare = self.savingsDistributor.distributeInterestAndReinvest(
                    vault: <- savingsVault,
                    totalDeposited: self.totalDeposited,
                    yieldSink: &self.config.yieldConnector as &{DeFiActions.Sink}
                )
                
                // AUTO-COMPOUND: Immediately update all user deposits with their earned interest
                let receiverIDs = self.getRegisteredReceiverIDs()
                var totalCompounded: UFix64 = 0.0
                var lastReceiverID: UInt64? = nil
                
                for receiverID in receiverIDs {
                    let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
                    if currentDeposit > 0.0 {
                        let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                        
                        if pending > 0.0 {
                            // Add interest to deposit
                            let newDeposit = currentDeposit + pending
                            self.receiverDeposits[receiverID] = newDeposit
                            totalCompounded = totalCompounded + pending
                            
                            // Update savings distributor to track the new balance
                            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
                            
                            // Track historical earnings
                            let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                            self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                            
                            emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
                            
                            // Track last receiver who got interest (for dust distribution)
                            lastReceiverID = receiverID
                        }
                    }
                }
                
                // Handle rounding dust: if there's a difference between what we distributed vs what we should have,
                // give the remainder to the last user (ensures no funds are lost to precision errors)
                if totalCompounded < plan.savingsAmount && lastReceiverID != nil {
                    let dust = plan.savingsAmount - totalCompounded
                    let lastReceiver = lastReceiverID!
                    let currentDep = self.receiverDeposits[lastReceiver] ?? 0.0
                    let newDepWithDust = currentDep + dust
                    self.receiverDeposits[lastReceiver] = newDepWithDust
                    
                    // Update savings distributor
                    self.savingsDistributor.updateAfterBalanceChange(receiverID: lastReceiver, newDeposit: newDepWithDust)
                    
                    // Track the dust as earnings
                    let currentSavings = self.receiverTotalEarnedSavings[lastReceiver] ?? 0.0
                    self.receiverTotalEarnedSavings[lastReceiver] = currentSavings + dust
                    
                    totalCompounded = plan.savingsAmount
                }
                
                // Update totalDeposited to reflect all compounded interest (now exact)
                self.totalDeposited = self.totalDeposited + totalCompounded
                // totalStaked was already updated when we reinvested
                self.totalStaked = self.totalStaked + plan.savingsAmount
                
                emit SavingsInterestDistributed(
                    poolID: self.poolID,
                    amount: plan.savingsAmount,
                    interestPerShare: interestPerShare
                )
            }
            
            if plan.lotteryAmount > 0.0 {
                var lotteryVault <- FlowToken.createEmptyVault(vaultType: self.config.assetType)
                
                // Take from yield first if available
                if yieldRewards != nil && yieldRewards?.balance! > 0.0 {
                    let yieldBalance = yieldRewards?.balance!
                    let fromYield = plan.lotteryAmount < yieldBalance ? plan.lotteryAmount : yieldBalance
                    let yieldRef = &yieldRewards as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
                    lotteryVault.deposit(from: <- yieldRef!.withdraw(amount: fromYield))
                }
                
                // Take remainder from other sources if needed
                if lotteryVault.balance < plan.lotteryAmount {
                    let remaining = plan.lotteryAmount - lotteryVault.balance
                    lotteryVault.deposit(from: <- self.rewardAggregator.withdrawCollected(amount: remaining))
                }
                
                // Fund the prize pool with lottery rewards (held until winners are drawn)
                self.lotteryDistributor.fundPrizePool(vault: <- lotteryVault)
            }
            
            if plan.treasuryAmount > 0.0 {
                var treasuryVault <- FlowToken.createEmptyVault(vaultType: self.config.assetType)
                
                // Take from yield first if available
                if yieldRewards != nil && yieldRewards?.balance! > 0.0 {
                    let yieldBalance = yieldRewards?.balance!
                    let fromYield = plan.treasuryAmount < yieldBalance ? plan.treasuryAmount : yieldBalance
                    let yieldRef = &yieldRewards as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
                    treasuryVault.deposit(from: <- yieldRef!.withdraw(amount: fromYield))
                }
                
                // Take remainder from other sources if needed
                if treasuryVault.balance < plan.treasuryAmount {
                    let remaining = plan.treasuryAmount - treasuryVault.balance
                    treasuryVault.deposit(from: <- self.rewardAggregator.withdrawCollected(amount: remaining))
                }
                
                self.treasuryDistributor.deposit(vault: <- treasuryVault)
                
                emit TreasuryFunded(
                    poolID: self.poolID,
                    amount: plan.treasuryAmount,
                    source: "rewards"
                )
            }
            
            destroy yieldRewards
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: totalRewards,
                savingsAmount: plan.savingsAmount,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        access(all) fun contributeRewards(from: @{FungibleToken.Vault}, contributor: Address) {
            pre {
                !self.paused: "Pool is paused - reward contributions are temporarily disabled"
                from.getType() == self.config.assetType: "Invalid vault type"
            }
            
            let amount = from.balance
            let sourceRef = self.rewardAggregator.borrowSource(id: "contributions")! as! &DirectContributionSource
            sourceRef.contribute(from: <- from, contributor: contributor)
            
            emit RewardContributed(poolID: self.poolID, contributor: contributor, amount: amount)
        }
        
        access(all) fun startDraw() {
            pre {
                !self.paused: "Pool is paused - draws are temporarily disabled"
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            self.processRewards()
            let prizeAmount = self.lotteryDistributor.getPrizePoolBalance()
            assert(prizeAmount > 0.0, message: "No prize pool funds")
            
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
            
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            let selectionResult = self.config.winnerSelectionStrategy.selectWinners(
                randomNumber: randomNumber,
                receiverDeposits: self.receiverDeposits,
                totalPrizeAmount: totalPrizeAmount
            )
            
            let winners = selectionResult.winners
            let prizeAmounts = selectionResult.amounts
            if winners.length == 0 {
                emit PrizesAwarded(
                    poolID: self.poolID,
                    winners: [],
                    amounts: [],
                    round: self.lotteryDistributor.getPrizeRound()
                )
                log("⚠️  Draw completed with no depositors - ".concat(totalPrizeAmount.toString()).concat(" FLOW stays for next draw"))
                return
            }
            
            assert(winners.length == prizeAmounts.length, message: "Winners and prize amounts must match")
            let currentRound = self.lotteryDistributor.getPrizeRound() + 1
            self.lotteryDistributor.setPrizeRound(round: currentRound)
            var totalAwarded: UFix64 = 0.0
            var i = 0
            while i < winners.length {
                let winnerID = winners[i]
                let prizeAmount = prizeAmounts[i]
                
                // Withdraw prizes from the lottery prize pool
                let prizeVault <- self.lotteryDistributor.awardPrize(
                    receiverID: winnerID,
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                // Automatically compound all rewards into user's deposit
                // This maximizes yield and encourages long-term saving
                let currentDeposit = self.receiverDeposits[winnerID] ?? 0.0
                
                // Settle any pending savings interest by adding it to deposit
                // Since savings were already reinvested into yield during processRewards,
                // we just update the accounting to reflect this in the user's individual deposit
                let pendingSavings = self.savingsDistributor.claimInterest(receiverID: winnerID, deposit: currentDeposit)
                var newDeposit = currentDeposit
                
                if pendingSavings > 0.0 {
                    // Add pending savings to deposit (already in yield source from processRewards)
                    newDeposit = newDeposit + pendingSavings
                    self.totalDeposited = self.totalDeposited + pendingSavings
                    // totalStaked already includes this from processRewards, so don't add again
                    
                    // Track historical savings for user reference
                    let currentSavings = self.receiverTotalEarnedSavings[winnerID] ?? 0.0
                    self.receiverTotalEarnedSavings[winnerID] = currentSavings + pendingSavings
                }
                
                // Add lottery prize to deposit and reinvest into yield source
                newDeposit = newDeposit + prizeAmount
                self.receiverDeposits[winnerID] = newDeposit
                self.totalDeposited = self.totalDeposited + prizeAmount
                self.totalStaked = self.totalStaked + prizeAmount
                
                // Update savings distributor to track the new balance
                self.savingsDistributor.updateAfterBalanceChange(receiverID: winnerID, newDeposit: newDeposit)
                
                // Reinvest the prize into the yield source
                self.config.yieldConnector.depositCapacity(from: &prizeVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                destroy prizeVault
                
                // Track total prizes awarded for user reference
                let totalPrizes = self.receiverTotalEarnedPrizes[winnerID] ?? 0.0
                self.receiverTotalEarnedPrizes[winnerID] = totalPrizes + prizeAmount
                
                totalAwarded = totalAwarded + prizeAmount
                i = i + 1
            }
            
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
            
            emit PrizesAwarded(
                poolID: self.poolID,
                winners: winners,
                amounts: prizeAmounts,
                round: currentRound
            )
        }
        
        access(all) fun compoundSavingsInterest(receiverID: UInt64): UFix64 {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
            let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
            
            if pending > 0.0 {
                // Add pending savings to deposit (already in yield source from processRewards)
                let newDeposit = currentDeposit + pending
                self.receiverDeposits[receiverID] = newDeposit
                self.totalDeposited = self.totalDeposited + pending
                // totalStaked already includes this from processRewards, so don't add again
                
                // Update savings distributor to track the new balance
                self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
                
                // Track historical savings for user reference
                let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                
                emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
            }
            
            return pending
        }
        
        access(all) fun withdrawPrize(receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let prizeAmount = self.receiverPrizes[receiverID] ?? 0.0
            assert(prizeAmount > 0.0, message: "No prizes to withdraw")
            assert(self.liquidVault.balance >= prizeAmount, message: "Insufficient liquid vault balance")
            
            // Update tracking
            self.receiverPrizes[receiverID] = 0.0
            let totalClaimed = self.receiverTotalEarnedPrizes[receiverID] ?? 0.0
            self.receiverTotalEarnedPrizes[receiverID] = totalClaimed + prizeAmount
            
            let prizeVault <- self.liquidVault.withdraw(amount: prizeAmount)
            emit PrizeWithdrawn(poolID: self.poolID, receiverID: receiverID, amount: prizeAmount)
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
        
        access(contract) fun setDrawIntervalSeconds(interval: UFix64) {
            assert(!self.isDrawInProgress(), message: "Cannot change draw interval during an active draw")
            self.config.setDrawIntervalSeconds(interval: interval)
        }
        
        access(contract) fun registerRewardSource(id: String, source: @{RewardSource}) {
            self.rewardAggregator.registerSource(id: id, source: <- source)
        }
        
        access(contract) fun removeRewardSource(id: String) {
            self.rewardAggregator.removeSource(id: id)
        }
        
        access(all) fun getRewardSourceIDs(): [String] {
            return self.rewardAggregator.getSourceIDs()
        }
        
        access(all) fun getAvailableRewardsFromSource(sourceID: String): UFix64 {
            return self.rewardAggregator.getAvailableFromSource(id: sourceID)
        }
        
        access(contract) fun getRewardSourceName(id: String): String? {
            if let sourceRef = self.rewardAggregator.borrowSource(id: id) {
                return sourceRef.getSourceName()
            }
            return nil
        }
        
        access(all) fun canDrawNow(): Bool {
            return (getCurrentBlock().timestamp - self.lastDrawTimestamp) >= self.config.drawIntervalSeconds
        }
        
        access(all) fun getReceiverDeposit(receiverID: UInt64): UFix64 {
            return self.receiverDeposits[receiverID] ?? 0.0
        }
        
        access(all) fun getReceiverPrizes(receiverID: UInt64): UFix64 {
            return self.receiverPrizes[receiverID] ?? 0.0
        }
        
        access(all) fun getReceiverTotalEarnedSavings(receiverID: UInt64): UFix64 {
            return self.receiverTotalEarnedSavings[receiverID] ?? 0.0
        }
        
        access(all) fun getReceiverTotalEarnedPrizes(receiverID: UInt64): UFix64 {
            return self.receiverTotalEarnedPrizes[receiverID] ?? 0.0
        }
        
        access(all) fun getPendingSavingsInterest(receiverID: UInt64): UFix64 {
            let deposit = self.receiverDeposits[receiverID] ?? 0.0
            return self.savingsDistributor.calculatePendingInterest(receiverID: receiverID, deposit: deposit)
        }
        
        access(all) fun isReceiverRegistered(receiverID: UInt64): Bool {
            return self.registeredReceivers[receiverID] == true
        }
        
        access(all) fun getRegisteredReceiverIDs(): [UInt64] {
            return self.registeredReceivers.keys
        }
        
        access(all) fun isDrawInProgress(): Bool {
            return self.pendingDrawReceipt != nil
        }
        
        access(all) fun getConfig(): PoolConfig {
            return self.config
        }
        
        access(all) fun getLiquidBalance(): UFix64 {
            return self.liquidVault.balance
        }
        
        access(all) fun getSavingsPoolBalance(): UFix64 {
            return self.savingsDistributor.getInterestVaultBalance()
        }
        
        access(all) fun getTotalSavingsDistributed(): UFix64 {
            return self.savingsDistributor.getTotalDistributed()
        }
        
        /// Calculate current amount of savings generating yield in the yield source
        /// This is the difference between totalStaked (all funds in yield source) and totalDeposited (user deposits)
        access(all) fun getCurrentReinvestedSavings(): UFix64 {
            if self.totalStaked > self.totalDeposited {
                return self.totalStaked - self.totalDeposited
            }
            return 0.0
        }
        
        /// Get available yield rewards ready to be collected
        /// This is the difference between what's in the yield source and what we've tracked as staked
        access(all) fun getAvailableYieldRewards(): UFix64 {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let available = yieldSource.minimumAvailable()
            if available > self.totalStaked {
                return available - self.totalStaked
            }
            return 0.0
        }
        
        access(all) fun getLotteryPoolBalance(): UFix64 {
            return self.lotteryDistributor.getPrizePoolBalance()
        }
        
        access(all) fun getTreasuryBalance(): UFix64 {
            return self.treasuryDistributor.getBalance()
        }
        
        access(all) fun getTreasuryStats(): {String: UFix64} {
            return {
                "balance": self.treasuryDistributor.getBalance(),
                "totalCollected": self.treasuryDistributor.getTotalCollected(),
                "totalWithdrawn": self.treasuryDistributor.getTotalWithdrawn()
            }
        }
        
        access(all) fun getTreasuryWithdrawalHistory(): [{String: AnyStruct}] {
            return self.treasuryDistributor.getWithdrawalHistory()
        }
        
        access(contract) fun withdrawTreasury(
            amount: UFix64,
            withdrawnBy: Address,
            purpose: String
        ): @{FungibleToken.Vault} {
            return <- self.treasuryDistributor.withdraw(
                amount: amount,
                withdrawnBy: withdrawnBy,
                purpose: purpose
            )
        }
        
    }
    
    // Pool Position Collection
    
    access(all) struct PoolBalance {
        access(all) let deposits: UFix64  // Total deposited (includes auto-compounded savings & prizes)
        access(all) let prizes: UFix64  // Always 0 - prizes are auto-compounded into deposits
        access(all) let totalEarnedSavings: UFix64  // Historical: total savings earned (auto-compounded)
        access(all) let totalEarnedPrizes: UFix64  // Historical: total prizes earned (auto-compounded)
        access(all) let pendingSavings: UFix64  // Savings not yet compounded (ready to compound)
        access(all) let totalBalance: UFix64  // deposits + pendingSavings (total in yield sink)
        
        init(deposits: UFix64, prizes: UFix64, totalEarnedSavings: UFix64, totalEarnedPrizes: UFix64, pendingSavings: UFix64) {
            self.deposits = deposits
            self.prizes = prizes  // Will always be 0 since prizes auto-compound
            self.totalEarnedSavings = totalEarnedSavings
            self.totalEarnedPrizes = totalEarnedPrizes
            self.pendingSavings = pendingSavings
            self.totalBalance = deposits + pendingSavings
        }
    }
    
    access(all) resource interface PoolPositionCollectionPublic {
        access(all) fun getRegisteredPoolIDs(): [UInt64]
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault})
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault}
        access(all) fun instantWithdraw(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault}
        access(all) fun compoundSavingsInterest(poolID: UInt64): UFix64
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
        
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid)
        }
        
        access(all) fun instantWithdraw(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.instantWithdraw(amount: amount, minOut: minOut, receiverID: self.uuid)
        }
        
        access(all) fun compoundSavingsInterest(poolID: UInt64): UFix64 {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return poolRef.compoundSavingsInterest(receiverID: self.uuid)
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
                return PoolBalance(deposits: 0.0, prizes: 0.0, totalEarnedSavings: 0.0, totalEarnedPrizes: 0.0, pendingSavings: 0.0)
            }
            
            let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            if poolRef == nil {
                return PoolBalance(deposits: 0.0, prizes: 0.0, totalEarnedSavings: 0.0, totalEarnedPrizes: 0.0, pendingSavings: 0.0)
            }
            
            return PoolBalance(
                deposits: poolRef!.getReceiverDeposit(receiverID: self.uuid),
                prizes: poolRef!.getReceiverPrizes(receiverID: self.uuid),
                totalEarnedSavings: poolRef!.getReceiverTotalEarnedSavings(receiverID: self.uuid),
                totalEarnedPrizes: poolRef!.getReceiverTotalEarnedPrizes(receiverID: self.uuid),
                pendingSavings: poolRef!.getPendingSavingsInterest(receiverID: self.uuid)
            )
        }
    }
    
    // Contract Functions
    access(all) entitlement PoolAccess
    
    access(contract) fun createPool(config: PoolConfig): UInt64 {
        pre {
            UInt64(self.pools.keys.length) < self.maxPools: "Maximum pool limit reached"
        }
        
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let pool <- create Pool(config: config, initialVault: <- emptyVault)
        
        let poolID = self.nextPoolID
            self.nextPoolID = self.nextPoolID + 1
            
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
    
    init() {
        self.PoolPositionCollectionStoragePath = /storage/PrizeVaultModularCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeVaultModularCollection
        
        self.AdminStoragePath = /storage/PrizeVaultModularAdmin
        self.AdminPublicPath = /public/PrizeVaultModularAdmin
        
        self.pools <- {}
        self.nextPoolID = 0
        self.maxPools = 100
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}

