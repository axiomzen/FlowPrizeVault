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
import "NonFungibleToken"
import "RandomConsumer"
import "DeFiActions"
import "DeFiActionsUtils"
import "PrizeWinnerTracker"
import "Xorshift128plus"

access(all) contract PrizeVaultModular {
    
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event RewardsCollected(poolID: UInt64, sourceID: String, amount: UFix64)
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    access(all) event RewardContributed(poolID: UInt64, contributor: Address, amount: UFix64)
    
    access(all) event SavingsInterestDistributed(poolID: UInt64, amount: UFix64, interestPerShare: UFix64)
    access(all) event SavingsInterestCompounded(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event SavingsRoundingDustToTreasury(poolID: UInt64, amount: UFix64)
    
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    access(all) event LotteryPrizePoolFunded(poolID: UInt64, amount: UFix64, source: String)
    
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, updatedBy: Address)
    access(all) event DrawIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, updatedBy: Address)
    access(all) event MinimumDepositUpdated(poolID: UInt64, oldMinimum: UFix64, newMinimum: UFix64, updatedBy: Address)
    access(all) event RewardSourceRegistered(poolID: UInt64, sourceID: String, sourceName: String, updatedBy: Address)
    access(all) event RewardSourceRemoved(poolID: UInt64, sourceID: String, updatedBy: Address)
    access(all) event PoolCreatedByAdmin(poolID: UInt64, assetType: String, strategy: String, createdBy: Address)
    
    access(all) event PoolPaused(poolID: UInt64, pausedBy: Address, reason: String)
    access(all) event PoolUnpaused(poolID: UInt64, unpausedBy: Address)
    access(all) event TreasuryFunded(poolID: UInt64, amount: UFix64, source: String)
    access(all) event TreasuryWithdrawn(poolID: UInt64, withdrawnBy: Address, amount: UFix64, purpose: String, remainingBalance: UFix64)
    
    access(all) event BonusLotteryWeightSet(poolID: UInt64, receiverID: UInt64, bonusWeight: UFix64, reason: String, setBy: Address, timestamp: UFix64)
    access(all) event BonusLotteryWeightAdded(poolID: UInt64, receiverID: UInt64, additionalWeight: UFix64, newTotalBonus: UFix64, reason: String, addedBy: Address, timestamp: UFix64)
    access(all) event BonusLotteryWeightRemoved(poolID: UInt64, receiverID: UInt64, previousBonus: UFix64, removedBy: Address, timestamp: UFix64)
    
    access(all) event NFTPrizeDeposited(poolID: UInt64, nftID: UInt64, nftType: String, depositedBy: Address)
    access(all) event NFTPrizeAwarded(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String, round: UInt64)
    access(all) event NFTPrizeStored(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String, reason: String)
    access(all) event NFTPrizeClaimed(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String)
    access(all) event NFTPrizeWithdrawn(poolID: UInt64, nftID: UInt64, nftType: String, withdrawnBy: Address)
    
    access(self) var pools: @{UInt64: Pool}
    access(self) var nextPoolID: UInt64
    
    // Bonus lottery weight tracking
    access(all) struct BonusWeightRecord {
        access(all) let bonusWeight: UFix64
        access(all) let reason: String
        access(all) let addedAt: UFix64
        access(all) let addedBy: Address
        
        access(contract) init(bonusWeight: UFix64, reason: String, addedBy: Address) {
            self.bonusWeight = bonusWeight
            self.reason = reason
            self.addedAt = getCurrentBlock().timestamp
            self.addedBy = addedBy
        }
    }
    
    // Admin resource can only be created by contract at init
    access(all) resource Admin {
        access(contract) init() {}
        
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
        
        access(all) fun updatePoolMinimumDeposit(
            poolID: UInt64,
            newMinimum: UFix64,
            updatedBy: Address
        ) {
            pre {
                newMinimum >= 0.0: "Minimum deposit cannot be negative"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let oldMinimum = poolRef.getConfig().minimumDeposit
            poolRef.setMinimumDeposit(minimum: newMinimum)
            
            emit MinimumDepositUpdated(
                poolID: poolID,
                oldMinimum: oldMinimum,
                newMinimum: newMinimum,
                updatedBy: updatedBy
            )
        }
        
        // Yield connector immutable per pool for security - create new pool for different yield protocol
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
        
        // Withdrawals not blocked during pause - users can always exit
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
        
        // All treasury withdrawals recorded on-chain for transparency
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
        
        access(all) fun registerPoolRewardSource(
            poolID: UInt64,
            sourceID: String,
            source: @{RewardSource},
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let sourceName = source.getSourceName()
            poolRef.registerRewardSource(id: sourceID, source: <- source)
            
            emit RewardSourceRegistered(
                poolID: poolID,
                sourceID: sourceID,
                sourceName: sourceName,
                updatedBy: updatedBy
            )
        }
        
        access(all) fun removePoolRewardSource(
            poolID: UInt64,
            sourceID: String,
            updatedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.removeRewardSource(id: sourceID)
            
            emit RewardSourceRemoved(
                poolID: poolID,
                sourceID: sourceID,
                updatedBy: updatedBy
            )
        }
        
        // Bonus lottery weight management
        access(all) fun setBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            bonusWeight: UFix64,
            reason: String,
            setBy: Address
        ) {
            pre {
                bonusWeight >= 0.0: "Bonus weight cannot be negative"
            }
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setBonusWeight(receiverID: receiverID, bonusWeight: bonusWeight, reason: reason, setBy: setBy)
        }
        
        access(all) fun addBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            additionalWeight: UFix64,
            reason: String,
            addedBy: Address
        ) {
            pre {
                additionalWeight > 0.0: "Additional weight must be positive"
            }
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.addBonusWeight(receiverID: receiverID, additionalWeight: additionalWeight, reason: reason, addedBy: addedBy)
        }
        
        access(all) fun removeBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            removedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.removeBonusWeight(receiverID: receiverID, removedBy: removedBy)
        }
        
        // NFT Prize Management
        access(all) fun depositNFTPrize(
            poolID: UInt64,
            nft: @{NonFungibleToken.NFT},
            depositedBy: Address
        ) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let nftID = nft.uuid
            let nftType = nft.getType().identifier
            
            poolRef.depositNFTPrize(nft: <- nft)
            
            emit NFTPrizeDeposited(
                poolID: poolID,
                nftID: nftID,
                nftType: nftType,
                depositedBy: depositedBy
            )
        }
        
        access(all) fun withdrawNFTPrize(
            poolID: UInt64,
            nftID: UInt64,
            withdrawnBy: Address
        ): @{NonFungibleToken.NFT} {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            let nft <- poolRef.withdrawNFTPrize(nftID: nftID)
            let nftType = nft.getType().identifier
            
            emit NFTPrizeWithdrawn(
                poolID: poolID,
                nftID: nftID,
                nftType: nftType,
                withdrawnBy: withdrawnBy
            )
            
            return <- nft
        }
    }
    
    access(all) let AdminStoragePath: StoragePath
    access(all) let AdminPublicPath: PublicPath
    
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
            self.contributionVault <- DeFiActionsUtils.getEmptyVault(vaultType)
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
                return <- DeFiActionsUtils.getEmptyVault(self.contributionVault.getType())
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
            self.collectedVault <- DeFiActionsUtils.getEmptyVault(vaultType)
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
            // PRECISION = 100 enables billion-scale distributions (up to ~1.84B FLOW per tx)
            // Provides 2 decimal places of precision (0.01 FLOW minimum)
            // Max safe amount = UFix64.max / PRECISION ≈ 1.84 billion FLOW
            self.PRECISION = 100.0
            self.accumulatedInterestPerShare = 0.0
            self.userClaimedAmount = {}
            self.interestVault <- DeFiActionsUtils.getEmptyVault(vaultType)
            self.totalDistributed = 0.0
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
            
            // Overflow protection: Check multiplication safety
            let maxSafeAmount = UFix64.max / self.PRECISION
            assert(amount <= maxSafeAmount, message: "Reward amount too large - would cause overflow")
            
            let interestPerShare = (amount * self.PRECISION) / totalDeposited
            
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
        
        /// Withdraw interest, using yield source if interestVault is insufficient (for reinvested savings)
        access(contract) fun withdrawInterestWithYieldSource(
            amount: UFix64,
            yieldSource: auth(FungibleToken.Withdraw) &{DeFiActions.Source}
        ): @{FungibleToken.Vault} {
            if amount == 0.0 {
                let vaultType = self.interestVault.getType()
                return <- DeFiActionsUtils.getEmptyVault(vaultType)
            }
            
            var remaining = amount
            let vaultType = self.interestVault.getType()
            var resultVault <- DeFiActionsUtils.getEmptyVault(vaultType)
            
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
        access(self) var nftPrizeVault: @{UInt64: {NonFungibleToken.NFT}}
        access(self) var pendingNFTClaims: @{UInt64: [{NonFungibleToken.NFT}]}
        access(self) var _prizeRound: UInt64
        access(all) var totalPrizesDistributed: UFix64
        
        access(all) fun getPrizeRound(): UInt64 {
            return self._prizeRound
        }
        
        access(contract) fun setPrizeRound(round: UInt64) {
            self._prizeRound = round
        }
        
        init(vaultType: Type) {
            self.prizeVault <- DeFiActionsUtils.getEmptyVault(vaultType)
            self.nftPrizeVault <- {}
            self.pendingNFTClaims <- {}
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
            
            var result <- DeFiActionsUtils.getEmptyVault(self.prizeVault.getType())
            
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
        
        // NFT Prize Management
        access(contract) fun depositNFTPrize(nft: @{NonFungibleToken.NFT}) {
            let nftID = nft.uuid
            self.nftPrizeVault[nftID] <-! nft
        }
        
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            let nft <- self.nftPrizeVault.remove(key: nftID)
            if nft == nil {
                panic("NFT not found in prize vault")
            }
            return <- nft!
        }
        
        access(contract) fun storePendingNFT(receiverID: UInt64, nft: @{NonFungibleToken.NFT}) {
            if self.pendingNFTClaims[receiverID] == nil {
                self.pendingNFTClaims[receiverID] <-! []
            }
            // Get mutable reference and append
            let arrayRef = &self.pendingNFTClaims[receiverID] as auth(Mutate) &[{NonFungibleToken.NFT}]?
            if arrayRef != nil {
                arrayRef!.append(<- nft)
            } else {
                destroy nft
                panic("Failed to store NFT in pending claims")
            }
        }
        
        access(all) fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.pendingNFTClaims[receiverID]?.length ?? 0
        }
        
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            let nfts = &self.pendingNFTClaims[receiverID] as &[{NonFungibleToken.NFT}]?
            if nfts == nil {
                return []
            }
            
            let ids: [UInt64] = []
            for nft in nfts! {
                ids.append(nft.uuid)
            }
            return ids
        }
        
        access(all) fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.nftPrizeVault.keys
        }
        
        access(all) fun borrowNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return &self.nftPrizeVault[nftID]
        }
        
        // Note: Cannot borrow pending NFTs directly due to Cadence limitations with nested resource references
        // Pending NFTs must be claimed first, then viewed in user's collection
        // Use getPendingNFTIDs() to get IDs, and display details after claiming
        
        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.pendingNFTClaims[receiverID] != nil: "No pending NFTs for this receiver"
                nftIndex < self.pendingNFTClaims[receiverID]?.length!: "Invalid NFT index"
            }
            return <- self.pendingNFTClaims[receiverID]?.remove(at: nftIndex)!
        }
    }
    
    // Treasury Distributor
    access(all) resource TreasuryDistributor {
        access(self) var treasuryVault: @{FungibleToken.Vault}
        access(all) var totalCollected: UFix64
        access(all) var totalWithdrawn: UFix64
        access(self) var withdrawalHistory: [{String: AnyStruct}]
        
        init(vaultType: Type) {
            self.treasuryVault <- DeFiActionsUtils.getEmptyVault(vaultType)
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
        access(all) let timeWeightedStakes: {UInt64: UFix64}  // Snapshot of stakes at draw start
        
        init(prizeAmount: UFix64, request: @RandomConsumer.Request, timeWeightedStakes: {UInt64: UFix64}) {
            self.prizeAmount = prizeAmount
            self.request <- request
            self.timeWeightedStakes = timeWeightedStakes
        }
        
        access(all) view fun getRequestBlock(): UInt64? {
            return self.request?.block
        }
        
        access(contract) fun popRequest(): @RandomConsumer.Request {
            let request <- self.request <- nil
            return <- request!
        }
        
        access(all) fun getTimeWeightedStakes(): {UInt64: UFix64} {
            return self.timeWeightedStakes
        }
    }
    
    // Winner Selection Strategy
    access(all) struct WinnerSelectionResult {
        access(all) let winners: [UInt64]
        access(all) let amounts: [UFix64]
        access(all) let nftIDs: [[UInt64]]
        
        init(winners: [UInt64], amounts: [UFix64], nftIDs: [[UInt64]]) {
            pre {
                winners.length == amounts.length: "Winners and amounts must have same length"
                winners.length == nftIDs.length: "Winners and nftIDs must have same length"
            }
            self.winners = winners
            self.amounts = amounts
            self.nftIDs = nftIDs
        }
    }
    
    /// Winner Selection Strategy Interface
    /// Note: receiverDeposits contains time-weighted lottery stakes (deposit + pending interest)
    /// This ensures users who have been in the pool longer have proportionally higher lottery chances
    access(all) struct interface WinnerSelectionStrategy {
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},  // Time-weighted stakes: deposit + pending interest
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult
        access(all) fun getStrategyName(): String
    }
    
    /// Weighted random selection - single winner
    /// Selection is weighted by time-weighted stake (deposit + pending interest)
    /// Users with larger deposits and/or longer time in pool have higher winning probability
    access(all) struct WeightedSingleWinner: WinnerSelectionStrategy {
        access(all) let nftIDs: [UInt64]
        
        init(nftIDs: [UInt64]) {
            self.nftIDs = nftIDs
        }
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            
            if receiverIDs.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            if receiverIDs.length == 1 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [self.nftIDs]
                )
            }
            
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                runningTotal = runningTotal + receiverDeposits[receiverID]!
                cumulativeSum.append(runningTotal)
            }
            
            // Safety check: prevent overflow if runningTotal is 0
            if runningTotal == 0.0 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [self.nftIDs]
                )
            }
            
            // Scale random number to [0, runningTotal) without overflow
            // Use modulo with safe upper bound (1 billion) for precision
            let scaledRandom = UFix64(randomNumber % 1_000_000_000) / 1_000_000_000.0
            let randomValue = scaledRandom * runningTotal
            
            var winnerIndex = 0
            for i, cumSum in cumulativeSum {
                if randomValue < cumSum {
                    winnerIndex = i
                    break
                }
            }
            
            return WinnerSelectionResult(
                winners: [receiverIDs[winnerIndex]],
                amounts: [totalPrizeAmount],
                nftIDs: [self.nftIDs]
            )
        }
        
        access(all) fun getStrategyName(): String {
            return "Weighted Single Winner"
        }
    }
    
    /// Multi-winner with split prizes
    /// Selection is weighted by time-weighted stake (deposit + pending interest)
    /// Users with larger deposits and/or longer time in pool have higher winning probability
    access(all) struct MultiWinnerSplit: WinnerSelectionStrategy {
        access(all) let winnerCount: Int
        access(all) let prizeSplits: [UFix64]  // e.g., [0.6, 0.3, 0.1] for 60%, 30%, 10%
        access(all) let nftIDsPerWinner: [[UInt64]]  // NFT IDs for each winner position, e.g., [[123], [456, 789], []]
        
        init(winnerCount: Int, prizeSplits: [UFix64], nftIDsPerWinner: [UInt64]) {
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
            
            // Distribute NFT IDs across winners
            // If nftIDsPerWinner is provided, assign them to winners in order
            // Otherwise, create empty arrays for each winner
            var nftArray: [[UInt64]] = []
            var nftIndex = 0
            var winnerIdx = 0
            while winnerIdx < winnerCount {
                if nftIndex < nftIDsPerWinner.length {
                    // Assign one NFT per winner in order
                    nftArray.append([nftIDsPerWinner[nftIndex]])
                    nftIndex = nftIndex + 1
                } else {
                    // No more NFTs, assign empty array
                    nftArray.append([])
                }
                winnerIdx = winnerIdx + 1
            }
            self.nftIDsPerWinner = nftArray
        }
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            let depositorCount = receiverIDs.length
            
            if depositorCount == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            assert(self.winnerCount <= depositorCount, message: "More winners than depositors")
            
            if depositorCount == 1 {
                // If only one depositor, they get all NFTs assigned to first winner position
                let nftIDsForFirst: [UInt64] = self.nftIDsPerWinner.length > 0 ? self.nftIDsPerWinner[0] : []
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [nftIDsForFirst]
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
            
            // Initialize Xorshift128plus PRG with the random beacon value
            // Use empty salt as the randomNumber already comes from a secure source (Flow's random beacon)
            // Pad to 16 bytes (PRG requires at least 16 bytes)
            var randomBytes = randomNumber.toBigEndianBytes()
            // Pad by duplicating the bytes to reach 16 bytes
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
            // Take only first 16 bytes if we have more
            var paddedBytes: [UInt8] = []
            var padIdx = 0
            while padIdx < 16 {
                paddedBytes.append(randomBytes[padIdx % randomBytes.length])
                padIdx = padIdx + 1
            }
            
            let prg = Xorshift128plus.PRG(
                sourceOfRandomness: paddedBytes,
                salt: []
            )
            
            var winnerIndex = 0
                while winnerIndex < self.winnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    let rng = prg.nextUInt64()
                    // Scale RNG to [0, remainingTotal) without overflow
                    // Use modulo with safe upper bound (1 billion) for precision
                    let scaledRandom = UFix64(rng % 1_000_000_000) / 1_000_000_000.0
                    let randomValue = scaledRandom * remainingTotal
                
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
            
            // Assign NFT IDs to winners based on their position
            // First winner gets first NFT set, second winner gets second NFT set, etc.
            var nftIDsArray: [[UInt64]] = []
            var idx2 = 0
            while idx2 < selectedWinners.length {
                if idx2 < self.nftIDsPerWinner.length {
                    nftIDsArray.append(self.nftIDsPerWinner[idx2])
                } else {
                    nftIDsArray.append([])
                }
                idx2 = idx2 + 1
            }
            
            return WinnerSelectionResult(
                winners: selectedWinners,
                amounts: prizeAmounts,
                nftIDs: nftIDsArray
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
    
    /// Prize tier for fixed-amount lottery
    access(all) struct PrizeTier {
        access(all) let prizeAmount: UFix64
        access(all) let winnerCount: Int
        access(all) let name: String
        access(all) let nftIDs: [UInt64]
        
        init(amount: UFix64, count: Int, name: String, nftIDs: [UInt64]) {
            pre {
                amount > 0.0: "Prize amount must be positive"
                count > 0: "Winner count must be positive"
                nftIDs.length <= count: "Cannot have more NFTs than winners in tier"
            }
            self.prizeAmount = amount
            self.winnerCount = count
            self.name = name
            self.nftIDs = nftIDs
        }
    }
    
    /// Fixed prize tiers - only draws when sufficient funds accumulated
    /// Best for marketing: "Win $10,000!" instead of variable percentages
    /// Selection is weighted by time-weighted stake (deposit + pending interest)
    access(all) struct FixedPrizeTiers: WinnerSelectionStrategy {
        access(all) let tiers: [PrizeTier]
        
        init(tiers: [PrizeTier]) {
            pre {
                tiers.length > 0: "Must have at least one prize tier"
                tiers.length <= 10: "Maximum 10 prize tiers"
            }
            self.tiers = tiers
        }
        
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverDeposits.keys
            let depositorCount = receiverIDs.length
            
            if depositorCount == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Calculate total needed for all tiers
            var totalNeeded: UFix64 = 0.0
            var totalWinnersNeeded = 0
            for tier in self.tiers {
                totalNeeded = totalNeeded + (tier.prizeAmount * UFix64(tier.winnerCount))
                totalWinnersNeeded = totalWinnersNeeded + tier.winnerCount
            }
            
            // Not enough funds - skip draw and let prize pool accumulate
            if totalPrizeAmount < totalNeeded {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Not enough depositors for all prizes
            if totalWinnersNeeded > depositorCount {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Build cumulative distribution for weighted selection
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                let deposit = receiverDeposits[receiverID]!
                runningTotal = runningTotal + deposit
                cumulativeSum.append(runningTotal)
            }
            
            // Initialize PRG - pad to 16 bytes (PRG requires at least 16 bytes)
            var randomBytes = randomNumber.toBigEndianBytes()
            // Pad by duplicating the bytes to reach 16 bytes
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
            // Take only first 16 bytes if we have more
            var paddedBytes: [UInt8] = []
            var padIdx2 = 0
            while padIdx2 < 16 {
                paddedBytes.append(randomBytes[padIdx2 % randomBytes.length])
                padIdx2 = padIdx2 + 1
            }
            
            let prg = Xorshift128plus.PRG(
                sourceOfRandomness: paddedBytes,
                salt: []
            )
            
            var allWinners: [UInt64] = []
            var allPrizes: [UFix64] = []
            var allNFTIDs: [[UInt64]] = []
            var usedIndices: {Int: Bool} = {}
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            // Select winners for each tier
            for tier in self.tiers {
                var tierWinnerCount = 0
                
                while tierWinnerCount < tier.winnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    let rng = prg.nextUInt64()
                    // Scale RNG to [0, remainingTotal) without overflow
                    // Use modulo with safe upper bound (1 billion) for precision
                    let scaledRandom = UFix64(rng % 1_000_000_000) / 1_000_000_000.0
                    let randomValue = scaledRandom * remainingTotal
                    
                    var selectedIdx = 0
                    for i, cumSum in remainingCumSum {
                        if randomValue <= cumSum {
                            selectedIdx = i
                            break
                        }
                    }
                    
                    let winnerID = remainingIDs[selectedIdx]
                    allWinners.append(winnerID)
                    allPrizes.append(tier.prizeAmount)
                    
                    // Assign NFT to this winner if tier has NFTs
                    if tierWinnerCount < tier.nftIDs.length {
                        allNFTIDs.append([tier.nftIDs[tierWinnerCount]])
                    } else {
                        allNFTIDs.append([])
                    }
                    
                    // Remove winner from remaining pool
                    var newRemainingIDs: [UInt64] = []
                    var newRemainingCumSum: [UFix64] = []
                    var newRunningTotal: UFix64 = 0.0
                    var oldIdx = 0
                    
                    while oldIdx < remainingIDs.length {
                        if oldIdx != selectedIdx {
                            newRemainingIDs.append(remainingIDs[oldIdx])
                            let deposit = receiverDeposits[remainingIDs[oldIdx]]!
                            newRunningTotal = newRunningTotal + deposit
                            newRemainingCumSum.append(newRunningTotal)
                        }
                        oldIdx = oldIdx + 1
                    }
                    
                    remainingIDs = newRemainingIDs
                    remainingCumSum = newRemainingCumSum
                    remainingTotal = newRunningTotal
                    tierWinnerCount = tierWinnerCount + 1
                }
            }
            
            return WinnerSelectionResult(
                winners: allWinners,
                amounts: allPrizes,
                nftIDs: allNFTIDs
            )
        }
        
        access(all) fun getStrategyName(): String {
            var name = "Fixed Prizes ("
            var idx = 0
            while idx < self.tiers.length {
                if idx > 0 {
                    name = name.concat(", ")
                }
                let tier = self.tiers[idx]
                name = name.concat(tier.winnerCount.toString())
                    .concat("x ")
                    .concat(tier.prizeAmount.toString())
                idx = idx + 1
            }
            return name.concat(")")
        }
    }
    
    // Pool Configuration
    access(all) struct PoolConfig {
        access(all) let assetType: Type
        access(all) let yieldConnector: {DeFiActions.Sink, DeFiActions.Source}
        access(all) var minimumDeposit: UFix64
        access(all) var drawIntervalSeconds: UFix64
        access(all) var distributionStrategy: {DistributionStrategy}
        access(all) var winnerSelectionStrategy: {WinnerSelectionStrategy}
        access(all) var winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        
        init(
            assetType: Type,
            yieldConnector: {DeFiActions.Sink, DeFiActions.Source},
            minimumDeposit: UFix64,
            drawIntervalSeconds: UFix64,
            distributionStrategy: {DistributionStrategy},
            winnerSelectionStrategy: {WinnerSelectionStrategy},
            winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        ) {
            self.assetType = assetType
            self.yieldConnector = yieldConnector
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
                interval >= 1.0: "Draw interval must be at least 1 hour (1 seconds)"
            }
            self.drawIntervalSeconds = interval
        }
        
        access(contract) fun setMinimumDeposit(minimum: UFix64) {
            pre {
                minimum >= 0.0: "Minimum deposit cannot be negative"
            }
            self.minimumDeposit = minimum
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
        access(self) let receiverBonusWeights: {UInt64: BonusWeightRecord}
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
            self.receiverBonusWeights = {}
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
            var pendingCompounded: UFix64 = 0.0
            
            if !isFirstDeposit {
                let currentDeposit = self.receiverDeposits[receiverID]!
                let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                if pending > 0.0 {
                    // Add pending to the user's deposit and totalStaked
                    self.receiverDeposits[receiverID] = currentDeposit + pending
                    pendingCompounded = pending
                    self.totalDeposited = self.totalDeposited + pending
                    self.totalStaked = self.totalStaked + pending
                    
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
                self.totalStaked = self.totalStaked + pending
                
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
        
        access(all) fun processRewards() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let availableYield = yieldBalance > self.totalStaked ? yieldBalance - self.totalStaked : 0.0
            
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
                var savingsVault <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
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
                
                for receiverID in receiverIDs {
                    let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
                    if currentDeposit > 0.0 {
                        let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                        
                        if pending > 0.0 {
                            // Add interest to deposit
                            let newDeposit = currentDeposit + pending
                            self.receiverDeposits[receiverID] = newDeposit
                            totalCompounded = totalCompounded + pending
                            
                            // Update totalStaked to include the compounded interest
                            self.totalStaked = self.totalStaked + pending
                            
                            // Update savings distributor to track the new balance
                            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
                            
                            // Track historical earnings
                            let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                            self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                            
                            emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
                        }
                    }
                }
                
                // Handle rounding dust: if there's a difference between what we distributed vs what we should have,
                // send the remainder to treasury (ensures fairness and no funds are lost to precision errors)
                if totalCompounded < plan.savingsAmount {
                    let dust = plan.savingsAmount - totalCompounded
                    
                    // Withdraw dust from yield source and deposit into treasury
                    let dustVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: dust)
                    self.treasuryDistributor.deposit(vault: <- dustVault)
                    
                    emit SavingsRoundingDustToTreasury(
                        poolID: self.poolID,
                        amount: dust
                    )
                }
                
                // Update totalDeposited to reflect all compounded interest (now exact)
                self.totalDeposited = self.totalDeposited + totalCompounded
                // Note: totalStaked was already updated incrementally in the loop above
                
                emit SavingsInterestDistributed(
                    poolID: self.poolID,
                    amount: plan.savingsAmount,
                    interestPerShare: interestPerShare
                )
            }
            
            if plan.lotteryAmount > 0.0 {
                var lotteryVault <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
                
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
                
                emit LotteryPrizePoolFunded(
                    poolID: self.poolID,
                    amount: plan.lotteryAmount,
                    source: "rewards"
                )
            }
            
            if plan.treasuryAmount > 0.0 {
                var treasuryVault <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
                
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
        
        access(all) fun contributeRewards(from: @{FungibleToken.Vault}, contributor: Address, sourceID: String) {
            pre {
                !self.paused: "Pool is paused - reward contributions are temporarily disabled"
                from.getType() == self.config.assetType: "Invalid vault type"
            }
            
            let amount = from.balance
            let sourceRef = self.rewardAggregator.borrowSource(id: sourceID)
                ?? panic("Reward source not found: ".concat(sourceID))
            
            // Cast to DirectContributionSource to access contribute function
            let contributionSourceRef = sourceRef as! &DirectContributionSource
            contributionSourceRef.contribute(from: <- from, contributor: contributor)
            
            emit RewardContributed(poolID: self.poolID, contributor: contributor, amount: amount)
        }
        
        access(all) fun startDraw() {
            pre {
                !self.paused: "Pool is paused - draws are temporarily disabled"
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            // SNAPSHOT: Calculate time-weighted lottery stakes BEFORE processRewards()
            // This captures the true time-weighted advantage of long-term depositors
            // because pending interest reflects their time in pool
            // BONUS WEIGHTS: Include referral/bonus lottery tickets in the snapshot
            let timeWeightedStakes: {UInt64: UFix64} = {}
            for receiverID in self.receiverDeposits.keys {
                let deposit = self.receiverDeposits[receiverID]!
                let pending = self.savingsDistributor.calculatePendingInterest(receiverID: receiverID, deposit: deposit)
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let timeWeightedStake = deposit + pending + bonusWeight
                
                // Only include users with non-zero stakes (saves gas/storage)
                if timeWeightedStake > 0.0 {
                    timeWeightedStakes[receiverID] = timeWeightedStake
                }
            }
            
            // Process rewards AFTER snapshotting - this will auto-compound interest
            // but won't affect the lottery odds for this draw
            self.processRewards()
            
            let prizeAmount = self.lotteryDistributor.getPrizePoolBalance()
            assert(prizeAmount > 0.0, message: "No prize pool funds")
            
            let randomRequest <- self.randomConsumer.requestRandomness()
            let receipt <- create PrizeDrawReceipt(
                prizeAmount: prizeAmount,
                request: <- randomRequest,
                timeWeightedStakes: timeWeightedStakes
            )
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
            
            // Retrieve the time-weighted stakes that were snapshotted at startDraw()
            // This ensures lottery odds are based on time in pool BEFORE auto-compounding
            let timeWeightedStakes = unwrappedReceipt.getTimeWeightedStakes()
            
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            
            let selectionResult = self.config.winnerSelectionStrategy.selectWinners(
                randomNumber: randomNumber,
                receiverDeposits: timeWeightedStakes,
                totalPrizeAmount: totalPrizeAmount
            )
            
            let winners = selectionResult.winners
            let prizeAmounts = selectionResult.amounts
            let nftIDsPerWinner = selectionResult.nftIDs
            
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
            assert(winners.length == nftIDsPerWinner.length, message: "Winners and NFT IDs must match")
            
            let currentRound = self.lotteryDistributor.getPrizeRound() + 1
            self.lotteryDistributor.setPrizeRound(round: currentRound)
            var totalAwarded: UFix64 = 0.0
            var i = 0
            while i < winners.length {
                let winnerID = winners[i]
                let prizeAmount = prizeAmounts[i]
                let nftIDsForWinner = nftIDsPerWinner[i]
                
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
                    // Add pending savings to deposit
                    newDeposit = newDeposit + pendingSavings
                    self.totalDeposited = self.totalDeposited + pendingSavings
                    self.totalStaked = self.totalStaked + pendingSavings
                    
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
                
                // Distribute NFT prizes to this winner
                for nftID in nftIDsForWinner {
                    // Check if NFT exists in vault before attempting withdrawal
                    let availableNFTs = self.lotteryDistributor.getAvailableNFTPrizeIDs()
                    var nftFound = false
                    for availableID in availableNFTs {
                        if availableID == nftID {
                            nftFound = true
                            break
                        }
                    }
                    
                    if !nftFound {
                        continue
                    }
                    
                    let nft <- self.lotteryDistributor.withdrawNFTPrize(nftID: nftID)
                    let nftType = nft.getType().identifier
                    
                    // Try to send NFT directly to winner
                    // For now, store as pending claim since we don't have their collection reference here
                    // Winner will need to claim via separate transaction
                    self.lotteryDistributor.storePendingNFT(receiverID: winnerID, nft: <- nft)
                    
                    emit NFTPrizeStored(
                        poolID: self.poolID,
                        receiverID: winnerID,
                        nftID: nftID,
                        nftType: nftType,
                        reason: "Lottery win - round ".concat(currentRound.toString())
                    )
                    
                    emit NFTPrizeAwarded(
                        poolID: self.poolID,
                        receiverID: winnerID,
                        nftID: nftID,
                        nftType: nftType,
                        round: currentRound
                    )
                }
                
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
                            amount: prizeAmounts[idx],
                            nftIDs: nftIDsPerWinner[idx]
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
                // Add pending savings to deposit
                let newDeposit = currentDeposit + pending
                self.receiverDeposits[receiverID] = newDeposit
                self.totalDeposited = self.totalDeposited + pending
                self.totalStaked = self.totalStaked + pending
                
                // Update savings distributor to track the new balance
                self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
                
                // Track historical savings for user reference
                let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                
                emit SavingsInterestCompounded(poolID: self.poolID, receiverID: receiverID, amount: pending)
            }
            
            return pending
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
        
        access(contract) fun setMinimumDeposit(minimum: UFix64) {
            self.config.setMinimumDeposit(minimum: minimum)
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
        
        // Bonus lottery weight management
        access(contract) fun setBonusWeight(receiverID: UInt64, bonusWeight: UFix64, reason: String, setBy: Address) {
            let timestamp = getCurrentBlock().timestamp
            let record = BonusWeightRecord(bonusWeight: bonusWeight, reason: reason, addedBy: setBy)
            self.receiverBonusWeights[receiverID] = record
            
            emit BonusLotteryWeightSet(
                poolID: self.poolID,
                receiverID: receiverID,
                bonusWeight: bonusWeight,
                reason: reason,
                setBy: setBy,
                timestamp: timestamp
            )
        }
        
        access(contract) fun addBonusWeight(receiverID: UInt64, additionalWeight: UFix64, reason: String, addedBy: Address) {
            let timestamp = getCurrentBlock().timestamp
            let currentBonus = self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
            let newTotalBonus = currentBonus + additionalWeight
            
            let record = BonusWeightRecord(bonusWeight: newTotalBonus, reason: reason, addedBy: addedBy)
            self.receiverBonusWeights[receiverID] = record
            
            emit BonusLotteryWeightAdded(
                poolID: self.poolID,
                receiverID: receiverID,
                additionalWeight: additionalWeight,
                newTotalBonus: newTotalBonus,
                reason: reason,
                addedBy: addedBy,
                timestamp: timestamp
            )
        }
        
        access(contract) fun removeBonusWeight(receiverID: UInt64, removedBy: Address) {
            let timestamp = getCurrentBlock().timestamp
            let previousBonus = self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
            
            let _ = self.receiverBonusWeights.remove(key: receiverID)
            
            emit BonusLotteryWeightRemoved(
                poolID: self.poolID,
                receiverID: receiverID,
                previousBonus: previousBonus,
                removedBy: removedBy,
                timestamp: timestamp
            )
        }
        
        access(all) fun getBonusWeight(receiverID: UInt64): UFix64 {
            return self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
        }
        
        access(all) fun getBonusWeightRecord(receiverID: UInt64): BonusWeightRecord? {
            return self.receiverBonusWeights[receiverID]
        }
        
        access(all) fun getAllBonusWeightReceivers(): [UInt64] {
            return self.receiverBonusWeights.keys
        }
        
        // NFT Prize Management (delegated to LotteryDistributor)
        access(contract) fun depositNFTPrize(nft: @{NonFungibleToken.NFT}) {
            self.lotteryDistributor.depositNFTPrize(nft: <- nft)
        }
        
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            return <- self.lotteryDistributor.withdrawNFTPrize(nftID: nftID)
        }
        
        access(all) fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.lotteryDistributor.getAvailableNFTPrizeIDs()
        }
        
        access(all) fun borrowAvailableNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return self.lotteryDistributor.borrowNFTPrize(nftID: nftID)
        }
        
        access(all) fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.lotteryDistributor.getPendingNFTCount(receiverID: receiverID)
        }
        
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            return self.lotteryDistributor.getPendingNFTIDs(receiverID: receiverID)
        }
        
        // Note: Pending NFTs cannot be borrowed directly due to Cadence limitations
        // Use getPendingNFTIDs() to see what's pending, then claim and view in wallet
        
        access(all) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            let nft <- self.lotteryDistributor.claimPendingNFT(receiverID: receiverID, nftIndex: nftIndex)
            let nftType = nft.getType().identifier
            
            emit NFTPrizeClaimed(
                poolID: self.poolID,
                receiverID: receiverID,
                nftID: nft.uuid,
                nftType: nftType
            )
            
            return <- nft
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
        access(all) let totalEarnedSavings: UFix64  // Historical: total savings earned (auto-compounded)
        access(all) let totalEarnedPrizes: UFix64  // Historical: total prizes earned (auto-compounded)
        access(all) let pendingSavings: UFix64  // Savings not yet compounded (ready to compound)
        access(all) let totalBalance: UFix64  // deposits + pendingSavings (total in yield sink)
        
        init(deposits: UFix64, totalEarnedSavings: UFix64, totalEarnedPrizes: UFix64, pendingSavings: UFix64) {
            self.deposits = deposits
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
        access(all) fun compoundSavingsInterest(poolID: UInt64): UFix64
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
        
        access(all) fun compoundSavingsInterest(poolID: UInt64): UFix64 {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return poolRef.compoundSavingsInterest(receiverID: self.uuid)
        }
        
        access(all) fun contributeRewards(poolID: UInt64, from: @{FungibleToken.Vault}, contributor: Address, sourceID: String) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.contributeRewards(from: <- from, contributor: contributor, sourceID: sourceID)
        }
        
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            if self.registeredPools[poolID] == nil {
                return PoolBalance(deposits: 0.0, totalEarnedSavings: 0.0, totalEarnedPrizes: 0.0, pendingSavings: 0.0)
            }
            
            let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            if poolRef == nil {
                return PoolBalance(deposits: 0.0, totalEarnedSavings: 0.0, totalEarnedPrizes: 0.0, pendingSavings: 0.0)
            }
            
            return PoolBalance(
                deposits: poolRef!.getReceiverDeposit(receiverID: self.uuid),
                totalEarnedSavings: poolRef!.getReceiverTotalEarnedSavings(receiverID: self.uuid),
                totalEarnedPrizes: poolRef!.getReceiverTotalEarnedPrizes(receiverID: self.uuid),
                pendingSavings: poolRef!.getPendingSavingsInterest(receiverID: self.uuid)
            )
        }
    }
    
    // Contract Functions
    access(all) entitlement PoolAccess
    
    access(contract) fun createPool(config: PoolConfig): UInt64 {
        let emptyVault <- DeFiActionsUtils.getEmptyVault(config.assetType)
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
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
