/*
PrizeSavings - Prize-Linked Savings Protocol

No-loss lottery where users deposit tokens to earn guaranteed savings interest and lottery prizes.
All rewards are automatically compounded into deposits via shares model.

Architecture:
- ERC4626-style shares model for O(1) interest distribution
- Modular yield sources via DeFi Actions interface
- Configurable distribution strategies (savings/lottery/treasury split)
- Pluggable winner selection strategies (weighted single, multi-winner, fixed tiers)
- Emergency mode with auto-recovery and health monitoring
- NFT prize support with pending claims system
- Direct funding for external sponsors with rate limits
- Bonus lottery weights for promotional campaigns

Core Components:
- SavingsDistributor: Shares-based vault for proportional interest distribution
- LotteryDistributor: Prize pool and NFT prize management
- TreasuryDistributor: Protocol reserves and fee collection
- Pool: Manages deposits, withdrawals, and prize draws per asset type
*/

import "FungibleToken"
import "NonFungibleToken"
import "RandomConsumer"
import "DeFiActions"
import "DeFiActionsUtils"
import "PrizeWinnerTracker"
import "Xorshift128plus"

access(all) contract PrizeSavings {
    
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    
    access(all) event SavingsYieldAccrued(poolID: UInt64, amount: UFix64)
    access(all) event SavingsInterestCompounded(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event SavingsInterestCompoundedBatch(poolID: UInt64, userCount: Int, totalAmount: UFix64, avgAmount: UFix64)
    access(all) event SavingsRoundingDustToTreasury(poolID: UInt64, amount: UFix64)
    
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    access(all) event LotteryPrizePoolFunded(poolID: UInt64, amount: UFix64, source: String)
    
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, updatedBy: Address)
    access(all) event DrawIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, updatedBy: Address)
    access(all) event MinimumDepositUpdated(poolID: UInt64, oldMinimum: UFix64, newMinimum: UFix64, updatedBy: Address)
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
    
    access(all) event PoolEmergencyEnabled(poolID: UInt64, reason: String, enabledBy: Address, timestamp: UFix64)
    access(all) event PoolEmergencyDisabled(poolID: UInt64, disabledBy: Address, timestamp: UFix64)
    access(all) event PoolPartialModeEnabled(poolID: UInt64, reason: String, setBy: Address, timestamp: UFix64)
    access(all) event EmergencyModeAutoTriggered(poolID: UInt64, reason: String, healthScore: UFix64, timestamp: UFix64)
    access(all) event EmergencyModeAutoRecovered(poolID: UInt64, reason: String, healthScore: UFix64?, duration: UFix64?, timestamp: UFix64)
    access(all) event EmergencyConfigUpdated(poolID: UInt64, updatedBy: Address)
    access(all) event WithdrawalFailure(poolID: UInt64, receiverID: UInt64, amount: UFix64, consecutiveFailures: Int, yieldAvailable: UFix64)
    
    access(all) event DirectFundingReceived(poolID: UInt64, destination: UInt8, destinationName: String, amount: UFix64, sponsor: Address, purpose: String, metadata: {String: String})
    
    access(self) var pools: @{UInt64: Pool}
    access(self) var nextPoolID: UInt64
    
    access(all) enum PoolEmergencyState: UInt8 {
        access(all) case Normal
        access(all) case Paused
        access(all) case EmergencyMode
        access(all) case PartialMode
    }
    
    access(all) enum PoolFundingDestination: UInt8 {
        access(all) case Savings
        access(all) case Lottery
        access(all) case Treasury
    }
    
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
    
    access(all) struct EmergencyConfig {
        access(all) let maxEmergencyDuration: UFix64?
        access(all) let autoRecoveryEnabled: Bool
        access(all) let minYieldSourceHealth: UFix64
        access(all) let maxWithdrawFailures: Int
        access(all) let partialModeDepositLimit: UFix64?
        access(all) let minBalanceThreshold: UFix64
        // Minimum health score required for time-based emergency recovery (defaults to 0.5)
        access(all) let minRecoveryHealth: UFix64
        
        init(
            maxEmergencyDuration: UFix64?,
            autoRecoveryEnabled: Bool,
            minYieldSourceHealth: UFix64,
            maxWithdrawFailures: Int,
            partialModeDepositLimit: UFix64?,
            minBalanceThreshold: UFix64,
            minRecoveryHealth: UFix64?
        ) {
            pre {
                minYieldSourceHealth >= 0.0 && minYieldSourceHealth <= 1.0: "Health must be between 0.0 and 1.0"
                maxWithdrawFailures > 0: "Must allow at least 1 withdrawal failure"
                minBalanceThreshold >= 0.8 && minBalanceThreshold <= 1.0: "Balance threshold must be between 0.8 and 1.0"
                minRecoveryHealth == nil || (minRecoveryHealth! >= 0.0 && minRecoveryHealth! <= 1.0): "minRecoveryHealth must be between 0.0 and 1.0"
            }
            self.maxEmergencyDuration = maxEmergencyDuration
            self.autoRecoveryEnabled = autoRecoveryEnabled
            self.minYieldSourceHealth = minYieldSourceHealth
            self.maxWithdrawFailures = maxWithdrawFailures
            self.partialModeDepositLimit = partialModeDepositLimit
            self.minBalanceThreshold = minBalanceThreshold
            self.minRecoveryHealth = minRecoveryHealth ?? 0.5
        }
    }
    
    access(all) struct FundingPolicy {
        access(all) let maxDirectLottery: UFix64?
        access(all) let maxDirectTreasury: UFix64?
        access(all) let maxDirectSavings: UFix64?
        access(all) var totalDirectLottery: UFix64
        access(all) var totalDirectTreasury: UFix64
        access(all) var totalDirectSavings: UFix64
        
        init(maxDirectLottery: UFix64?, maxDirectTreasury: UFix64?, maxDirectSavings: UFix64?) {
            self.maxDirectLottery = maxDirectLottery
            self.maxDirectTreasury = maxDirectTreasury
            self.maxDirectSavings = maxDirectSavings
            self.totalDirectLottery = 0.0
            self.totalDirectTreasury = 0.0
            self.totalDirectSavings = 0.0
        }
        
        access(contract) fun recordDirectFunding(destination: PoolFundingDestination, amount: UFix64) {
            switch destination {
                case PoolFundingDestination.Lottery:
                    self.totalDirectLottery = self.totalDirectLottery + amount
                    if self.maxDirectLottery != nil {
                        assert(self.totalDirectLottery <= self.maxDirectLottery!, message: "Direct lottery funding limit exceeded")
                    }
                case PoolFundingDestination.Treasury:
                    self.totalDirectTreasury = self.totalDirectTreasury + amount
                    if self.maxDirectTreasury != nil {
                        assert(self.totalDirectTreasury <= self.maxDirectTreasury!, message: "Direct treasury funding limit exceeded")
                    }
                case PoolFundingDestination.Savings:
                    self.totalDirectSavings = self.totalDirectSavings + amount
                    if self.maxDirectSavings != nil {
                        assert(self.totalDirectSavings <= self.maxDirectSavings!, message: "Direct savings funding limit exceeded")
                    }
            }
        }
    }
    
    access(all) fun createDefaultEmergencyConfig(): EmergencyConfig {
        return EmergencyConfig(
            maxEmergencyDuration: 86400.0,
            autoRecoveryEnabled: true,
            minYieldSourceHealth: 0.5,
            maxWithdrawFailures: 3,
            partialModeDepositLimit: 100.0,
            minBalanceThreshold: 0.95,
            minRecoveryHealth: 0.5
        )
    }
    
    access(all) fun createDefaultFundingPolicy(): FundingPolicy {
        return FundingPolicy(
            maxDirectLottery: nil,
            maxDirectTreasury: nil,
            maxDirectSavings: nil
        )
    }
    
    access(all) resource Admin {
        access(contract) init() {}
        
        access(all) fun updatePoolDistributionStrategy(
            poolID: UInt64,
            newStrategy: {DistributionStrategy},
            updatedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
        
        access(all) fun enableEmergencyMode(poolID: UInt64, reason: String, enabledBy: Address) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setEmergencyMode(reason: reason)
            emit PoolEmergencyEnabled(poolID: poolID, reason: reason, enabledBy: enabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(all) fun disableEmergencyMode(poolID: UInt64, disabledBy: Address) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.clearEmergencyMode()
            emit PoolEmergencyDisabled(poolID: poolID, disabledBy: disabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(all) fun setEmergencyPartialMode(poolID: UInt64, reason: String, setBy: Address) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setPartialMode(reason: reason)
            emit PoolPartialModeEnabled(poolID: poolID, reason: reason, setBy: setBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(all) fun updateEmergencyConfig(poolID: UInt64, newConfig: EmergencyConfig, updatedBy: Address) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setEmergencyConfig(config: newConfig)
            emit EmergencyConfigUpdated(poolID: poolID, updatedBy: updatedBy)
        }
        
        access(all) fun fundPoolDirect(
            poolID: UInt64,
            destination: PoolFundingDestination,
            from: @{FungibleToken.Vault},
            sponsor: Address,
            purpose: String,
            metadata: {String: String}?
        ) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            let amount = from.balance
            poolRef.fundDirectInternal(destination: destination, from: <- from, sponsor: sponsor, purpose: purpose, metadata: metadata ?? {})
            
            emit DirectFundingReceived(
                poolID: poolID,
                destination: destination.rawValue,
                destinationName: self.getDestinationName(destination),
                amount: amount,
                sponsor: sponsor,
                purpose: purpose,
                metadata: metadata ?? {}
            )
        }
        
        access(self) fun getDestinationName(_ destination: PoolFundingDestination): String {
            switch destination {
                case PoolFundingDestination.Savings: return "Savings"
                case PoolFundingDestination.Lottery: return "Lottery"
                case PoolFundingDestination.Treasury: return "Treasury"
                default: return "Unknown"
            }
        }
        
        access(all) fun createPool(
            config: PoolConfig,
            emergencyConfig: EmergencyConfig?,
            fundingPolicy: FundingPolicy?,
            createdBy: Address
        ): UInt64 {
            let finalEmergencyConfig = emergencyConfig 
                ?? PrizeSavings.createDefaultEmergencyConfig()
            let finalFundingPolicy = fundingPolicy 
                ?? PrizeSavings.createDefaultFundingPolicy()
            
            let poolID = PrizeSavings.createPool(
                config: config,
                emergencyConfig: finalEmergencyConfig,
                fundingPolicy: finalFundingPolicy
            )
            
            emit PoolCreatedByAdmin(
                poolID: poolID,
                assetType: config.assetType.identifier,
                strategy: config.distributionStrategy.getStrategyName(),
                createdBy: createdBy
            )
            
            return poolID
        }
        
        access(all) fun processPoolRewards(poolID: UInt64) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.processRewards()
        }
        
        access(all) fun setPoolState(poolID: UInt64, state: PoolEmergencyState, reason: String?, setBy: Address) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setState(state: state, reason: reason)
            
            switch state {
                case PoolEmergencyState.Normal:
                    emit PoolUnpaused(poolID: poolID, unpausedBy: setBy)
                case PoolEmergencyState.Paused:
                    emit PoolPaused(poolID: poolID, pausedBy: setBy, reason: reason ?? "Manual pause")
                case PoolEmergencyState.EmergencyMode:
                    emit PoolEmergencyEnabled(poolID: poolID, reason: reason ?? "Emergency", enabledBy: setBy, timestamp: getCurrentBlock().timestamp)
                case PoolEmergencyState.PartialMode:
                    emit PoolPartialModeEnabled(poolID: poolID, reason: reason ?? "Partial mode", setBy: setBy, timestamp: getCurrentBlock().timestamp)
            }
        }
        
        access(all) fun withdrawPoolTreasury(
            poolID: UInt64,
            amount: UFix64,
            purpose: String,
            withdrawnBy: Address
        ): @{FungibleToken.Vault} {
            pre {
                purpose.length > 0: "Purpose must be specified for treasury withdrawal"
            }
            
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.addBonusWeight(receiverID: receiverID, additionalWeight: additionalWeight, reason: reason, addedBy: addedBy)
        }
        
        access(all) fun removeBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            removedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.removeBonusWeight(receiverID: receiverID, removedBy: removedBy)
        }
        
        access(all) fun depositNFTPrize(
            poolID: UInt64,
            nft: @{NonFungibleToken.NFT},
            depositedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
    
    /// ERC4626-style shares distributor for O(1) interest distribution
    /// 
    /// Key relationship: totalAssets = what users collectively own (principal + accrued savings yield)
    /// This should equal Pool.totalStaked for the savings portion (funds stay in yield source)
    access(all) resource SavingsDistributor {
        /// Total shares minted across all users
        access(self) var totalShares: UFix64
        /// Total assets owned by all shareholders (principal + accrued yield)
        /// Updated on: deposit (+), accrueYield (+), withdraw (-)
        access(self) var totalAssets: UFix64
        /// Per-user share balances
        access(self) let userShares: {UInt64: UFix64}
        /// Cumulative yield distributed (for analytics)
        access(all) var totalDistributed: UFix64
        access(self) let vaultType: Type
        
        init(vaultType: Type) {
            self.totalShares = 0.0
            self.totalAssets = 0.0
            self.userShares = {}
            self.totalDistributed = 0.0
            self.vaultType = vaultType
        }
        
        access(contract) fun accrueYield(amount: UFix64) {
            if amount == 0.0 || self.totalShares == 0.0 {
                return
            }
            
            self.totalAssets = self.totalAssets + amount
            self.totalDistributed = self.totalDistributed + amount
        }
        
        access(contract) fun deposit(receiverID: UInt64, amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            let sharesToMint = self.convertToShares(amount)
            let currentShares = self.userShares[receiverID] ?? 0.0
            self.userShares[receiverID] = currentShares + sharesToMint
            self.totalShares = self.totalShares + sharesToMint
            self.totalAssets = self.totalAssets + amount
        }
        
        access(contract) fun withdraw(receiverID: UInt64, amount: UFix64): UFix64 {
            if amount == 0.0 {
                return 0.0
            }
            
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            assert(userShareBalance > 0.0, message: "No shares to withdraw")
            assert(self.totalShares > 0.0 && self.totalAssets > 0.0, message: "Invalid distributor state")
            
            let currentAssetValue = self.convertToAssets(userShareBalance)
            assert(amount <= currentAssetValue, message: "Insufficient balance")
            
            let sharesToBurn = (amount * self.totalShares) / self.totalAssets
            
            self.userShares[receiverID] = userShareBalance - sharesToBurn
            self.totalShares = self.totalShares - sharesToBurn
            self.totalAssets = self.totalAssets - amount
            
            return amount
        }
        
        access(all) view fun convertToShares(_ assets: UFix64): UFix64 {
            if self.totalShares == 0.0 || self.totalAssets == 0.0 {
                return assets
            }
            
            if assets > 0.0 && self.totalShares > 0.0 {
                let maxSafeAssets = UFix64.max / self.totalShares
                assert(assets <= maxSafeAssets, message: "Deposit amount too large - would cause overflow")
            }
            
            return (assets * self.totalShares) / self.totalAssets
        }
        
        access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
            if self.totalShares == 0.0 {
                return 0.0
            }
            
            if shares > 0.0 && self.totalAssets > 0.0 {
                let maxSafeShares = UFix64.max / self.totalAssets
                assert(shares <= maxSafeShares, message: "Share amount too large - would cause overflow")
            }
            
            return (shares * self.totalAssets) / self.totalShares
        }
        
        access(all) fun getUserAssetValue(receiverID: UInt64): UFix64 {
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            return self.convertToAssets(userShareBalance)
        }
        
        access(all) fun getTotalDistributed(): UFix64 {
            return self.totalDistributed
        }
        
        access(all) fun getTotalShares(): UFix64 {
            return self.totalShares
        }
        
        access(all) fun getTotalAssets(): UFix64 {
            return self.totalAssets
        }
        
        access(all) fun getUserShares(receiverID: UInt64): UFix64 {
            return self.userShares[receiverID] ?? 0.0
        }
    }
    
    access(all) resource LotteryDistributor {
        access(self) var prizeVault: @{FungibleToken.Vault}
        access(self) var nftPrizeSavings: @{UInt64: {NonFungibleToken.NFT}}
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
            self.nftPrizeSavings <- {}
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
            
            if yieldSource != nil {
                let available = yieldSource!.minimumAvailable()
                if available >= amount {
                    result.deposit(from: <- yieldSource!.withdrawAvailable(maxAmount: amount))
                    return <- result
                } else if available > 0.0 {
                    result.deposit(from: <- yieldSource!.withdrawAvailable(maxAmount: available))
                }
            }
            
            if result.balance < amount {
                let remaining = amount - result.balance
                assert(self.prizeVault.balance >= remaining, message: "Insufficient prize pool")
                result.deposit(from: <- self.prizeVault.withdraw(amount: remaining))
            }
            
            return <- result
        }
        
        access(contract) fun depositNFTPrize(nft: @{NonFungibleToken.NFT}) {
            let nftID = nft.uuid
            self.nftPrizeSavings[nftID] <-! nft
        }
        
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            let nft <- self.nftPrizeSavings.remove(key: nftID)
            if nft == nil {
                panic("NFT not found in prize vault")
            }
            return <- nft!
        }
        
        access(contract) fun storePendingNFT(receiverID: UInt64, nft: @{NonFungibleToken.NFT}) {
            if self.pendingNFTClaims[receiverID] == nil {
                self.pendingNFTClaims[receiverID] <-! []
            }
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
            return self.nftPrizeSavings.keys
        }
        
        access(all) fun borrowNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return &self.nftPrizeSavings[nftID]
        }

        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.pendingNFTClaims[receiverID] != nil: "No pending NFTs for this receiver"
                nftIndex < self.pendingNFTClaims[receiverID]?.length!: "Invalid NFT index"
            }
            return <- self.pendingNFTClaims[receiverID]?.remove(at: nftIndex)!
        }
    }
    
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
    
    access(all) resource PrizeDrawReceipt {
        access(all) let prizeAmount: UFix64
        access(self) var request: @RandomConsumer.Request?
        access(all) let timeWeightedStakes: {UInt64: UFix64}
        
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
    
    access(all) struct interface WinnerSelectionStrategy {
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverDeposits: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult
        access(all) fun getStrategyName(): String
    }
    
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
            
            if runningTotal == 0.0 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [self.nftIDs]
                )
            }
            
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
    
    access(all) struct MultiWinnerSplit: WinnerSelectionStrategy {
        access(all) let winnerCount: Int
        access(all) let prizeSplits: [UFix64]
        access(all) let nftIDsPerWinner: [[UInt64]]
        
        init(winnerCount: Int, prizeSplits: [UFix64], nftIDsPerWinner: [UInt64]) {
            pre {
                winnerCount > 0: "Must have at least one winner"
                prizeSplits.length == winnerCount: "Prize splits must match winner count"
            }
            
            var total: UFix64 = 0.0
            for split in prizeSplits {
                assert(split >= 0.0 && split <= 1.0, message: "Each split must be between 0 and 1")
                total = total + split
            }
            
            assert(total == 1.0, message: "Prize splits must sum to 1.0")
            
            self.winnerCount = winnerCount
            self.prizeSplits = prizeSplits
            
            var nftArray: [[UInt64]] = []
            var nftIndex = 0
            var winnerIdx = 0
            while winnerIdx < winnerCount {
                if nftIndex < nftIDsPerWinner.length {
                    nftArray.append([nftIDsPerWinner[nftIndex]])
                    nftIndex = nftIndex + 1
                } else {
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
            
            // Compute actual winner count - if fewer depositors than configured winners,
            // award prizes to all available depositors instead of panicking
            let actualWinnerCount = self.winnerCount < depositorCount ? self.winnerCount : depositorCount
            
            if depositorCount == 1 {
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
            
            var randomBytes = randomNumber.toBigEndianBytes()
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
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
                while winnerIndex < actualWinnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    let rng = prg.nextUInt64()
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
            
            let lastPrize = totalPrizeAmount - calculatedSum
            prizeAmounts.append(lastPrize)
            
            // Only validate deviation when we have the expected number of winners
            // When fewer depositors exist, the last winner gets the remainder which is expected
            if selectedWinners.length == self.winnerCount {
                let expectedLast = totalPrizeAmount * self.prizeSplits[selectedWinners.length - 1]
                let deviation = lastPrize > expectedLast ? lastPrize - expectedLast : expectedLast - lastPrize
                let maxDeviation = totalPrizeAmount * 0.01
                assert(deviation <= maxDeviation, message: "Last prize deviation too large - check splits")
            }
            
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
    
    access(all) struct FixedPrizeTiers: WinnerSelectionStrategy {
        access(all) let tiers: [PrizeTier]
        
        init(tiers: [PrizeTier]) {
            pre {
                tiers.length > 0: "Must have at least one prize tier"
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
            
            var totalNeeded: UFix64 = 0.0
            var totalWinnersNeeded = 0
            for tier in self.tiers {
                totalNeeded = totalNeeded + (tier.prizeAmount * UFix64(tier.winnerCount))
                totalWinnersNeeded = totalWinnersNeeded + tier.winnerCount
            }
            
            if totalPrizeAmount < totalNeeded {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            if totalWinnersNeeded > depositorCount {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                let deposit = receiverDeposits[receiverID]!
                runningTotal = runningTotal + deposit
                cumulativeSum.append(runningTotal)
            }
            
            var randomBytes = randomNumber.toBigEndianBytes()
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
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
            
            for tier in self.tiers {
                var tierWinnerCount = 0
                
                while tierWinnerCount < tier.winnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    let rng = prg.nextUInt64()
                    let scaledRandom = UFix64(rng % 1_000_000_000) / 1_000_000_000.0
                    let randomValue = scaledRandom * remainingTotal
                    
                    var selectedIdx = 0
                    for i, cumSum in remainingCumSum {
                        if randomValue < cumSum {
                            selectedIdx = i
                            break
                        }
                    }
                    
                    let winnerID = remainingIDs[selectedIdx]
                    allWinners.append(winnerID)
                    allPrizes.append(tier.prizeAmount)
                    
                    if tierWinnerCount < tier.nftIDs.length {
                        allNFTIDs.append([tier.nftIDs[tierWinnerCount]])
                    } else {
                        allNFTIDs.append([])
                    }
                    
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
                interval >= 1.0: "Draw interval must be at least 1 seconds"
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
    
    access(all) resource Pool {
        access(self) var config: PoolConfig
        access(self) var poolID: UInt64
        
        access(self) var emergencyState: PoolEmergencyState
        access(self) var emergencyReason: String?
        access(self) var emergencyActivatedAt: UFix64?
        access(self) var emergencyConfig: EmergencyConfig
        access(self) var consecutiveWithdrawFailures: Int
        
        access(self) var fundingPolicy: FundingPolicy
        
        access(contract) fun setPoolID(id: UInt64) {
            self.poolID = id
        }
        
        access(self) let receiverDeposits: {UInt64: UFix64}
        access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
        access(self) let receiverPrizes: {UInt64: UFix64}
        access(self) let registeredReceivers: {UInt64: Bool}
        access(self) let receiverBonusWeights: {UInt64: BonusWeightRecord}
        
        /// ACCOUNTING VARIABLES - Key relationships:
        /// 
        /// totalDeposited: Sum of user principal deposits only (excludes earned interest)
        ///   Updated on: deposit (+), withdraw principal (-)
        ///   
        /// totalStaked: Amount tracked as being in the yield source
        ///   Updated on: deposit (+), savings yield accrual (+), withdraw from yield source (-)
        ///   Should equal: yieldSourceBalance (approximately)
        ///   
        /// Invariant: totalStaked >= totalDeposited (difference is reinvested savings yield)
        /// 
        /// Note: SavingsDistributor.totalAssets tracks what users own and should equal totalStaked
        access(all) var totalDeposited: UFix64
        access(all) var totalStaked: UFix64
        access(all) var lotteryStaked: UFix64
        access(all) var lastDrawTimestamp: UFix64
        access(self) let savingsDistributor: @SavingsDistributor
        access(self) let lotteryDistributor: @LotteryDistributor
        access(self) let treasuryDistributor: @TreasuryDistributor
        
        access(self) var liquidVault: @{FungibleToken.Vault}
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        init(
            config: PoolConfig, 
            initialVault: @{FungibleToken.Vault},
            emergencyConfig: EmergencyConfig?,
            fundingPolicy: FundingPolicy?
        ) {
            pre {
                initialVault.getType() == config.assetType: "Vault type mismatch"
                initialVault.balance == 0.0: "Initial vault must be empty"
            }
            
            self.config = config
            self.poolID = 0
            
            self.emergencyState = PoolEmergencyState.Normal
            self.emergencyReason = nil
            self.emergencyActivatedAt = nil
            self.emergencyConfig = emergencyConfig ?? PrizeSavings.createDefaultEmergencyConfig()
            self.consecutiveWithdrawFailures = 0
            
            self.fundingPolicy = fundingPolicy ?? PrizeSavings.createDefaultFundingPolicy()
            
            self.receiverDeposits = {}
            self.receiverTotalEarnedPrizes = {}
            self.receiverPrizes = {}
            self.registeredReceivers = {}
            self.receiverBonusWeights = {}
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lotteryStaked = 0.0
            self.lastDrawTimestamp = 0.0
            
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            self.treasuryDistributor <- create TreasuryDistributor(vaultType: config.assetType)
            
            self.liquidVault <- initialVault
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
        }
        
        access(all) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            self.registeredReceivers[receiverID] = true
        }
        
        
        access(all) view fun getEmergencyState(): PoolEmergencyState {
            return self.emergencyState
        }
        
        access(all) view fun getEmergencyConfig(): EmergencyConfig {
            return self.emergencyConfig
        }
        
        access(contract) fun setState(state: PoolEmergencyState, reason: String?) {
            self.emergencyState = state
            if state != PoolEmergencyState.Normal {
                self.emergencyReason = reason
                self.emergencyActivatedAt = getCurrentBlock().timestamp
            } else {
                self.emergencyReason = nil
                self.emergencyActivatedAt = nil
                self.consecutiveWithdrawFailures = 0
            }
        }
        
        access(contract) fun setEmergencyMode(reason: String) {
            self.emergencyState = PoolEmergencyState.EmergencyMode
            self.emergencyReason = reason
            self.emergencyActivatedAt = getCurrentBlock().timestamp
        }
        
        access(contract) fun setPartialMode(reason: String) {
            self.emergencyState = PoolEmergencyState.PartialMode
            self.emergencyReason = reason
            self.emergencyActivatedAt = getCurrentBlock().timestamp
        }
        
        access(contract) fun clearEmergencyMode() {
            self.emergencyState = PoolEmergencyState.Normal
            self.emergencyReason = nil
            self.emergencyActivatedAt = nil
            self.consecutiveWithdrawFailures = 0
        }
        
        access(contract) fun setEmergencyConfig(config: EmergencyConfig) {
            self.emergencyConfig = config
        }
        
        access(all) view fun isEmergencyMode(): Bool {
            return self.emergencyState == PoolEmergencyState.EmergencyMode
        }
        
        access(all) view fun isPartialMode(): Bool {
            return self.emergencyState == PoolEmergencyState.PartialMode
        }
        
        access(all) fun getEmergencyInfo(): {String: AnyStruct}? {
            if self.emergencyState != PoolEmergencyState.Normal {
                let duration = getCurrentBlock().timestamp - (self.emergencyActivatedAt ?? 0.0)
                let health = self.checkYieldSourceHealth()
                return {
                    "state": self.emergencyState.rawValue,
                    "reason": self.emergencyReason ?? "Unknown",
                    "activatedAt": self.emergencyActivatedAt ?? 0.0,
                    "durationSeconds": duration,
                    "yieldSourceHealth": health,
                    "canAutoRecover": self.emergencyConfig.autoRecoveryEnabled,
                    "maxDuration": self.emergencyConfig.maxEmergencyDuration
                }
            }
            return nil
        }
        
        access(contract) fun checkYieldSourceHealth(): UFix64 {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let balance = yieldSource.minimumAvailable()
            let threshold = self.getEmergencyConfig().minBalanceThreshold
            let balanceHealthy = balance >= self.totalStaked * threshold
            let withdrawSuccessRate = self.consecutiveWithdrawFailures == 0 ? 1.0 : 
                (1.0 / UFix64(self.consecutiveWithdrawFailures + 1))
            
            var health: UFix64 = 0.0
            if balanceHealthy { health = health + 0.5 }
            health = health + (withdrawSuccessRate * 0.5)
            return health
        }
        
        access(contract) fun checkAndAutoTriggerEmergency(): Bool {
            if self.emergencyState != PoolEmergencyState.Normal {
                return false
            }
            
            let health = self.checkYieldSourceHealth()
            if health < self.emergencyConfig.minYieldSourceHealth {
                self.setEmergencyMode(reason: "Auto-triggered: Yield source health below threshold (".concat(health.toString()).concat(")"))
                emit EmergencyModeAutoTriggered(poolID: self.poolID, reason: "Low yield source health", healthScore: health, timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            if self.consecutiveWithdrawFailures >= self.emergencyConfig.maxWithdrawFailures {
                self.setEmergencyMode(reason: "Auto-triggered: Multiple consecutive withdrawal failures")
                emit EmergencyModeAutoTriggered(poolID: self.poolID, reason: "Withdrawal failures", healthScore: health, timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            return false
        }
        
        access(contract) fun checkAndAutoRecover(): Bool {
            if self.emergencyState != PoolEmergencyState.EmergencyMode {
                return false
            }
            
            if !self.emergencyConfig.autoRecoveryEnabled {
                return false
            }
            
            let health = self.checkYieldSourceHealth()
            
            // Health-based recovery: yield source is healthy
            if health >= 0.9 {
                self.clearEmergencyMode()
                emit EmergencyModeAutoRecovered(poolID: self.poolID, reason: "Yield source recovered", healthScore: health, duration: nil, timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            // Time-based recovery: only if health is not critically low
            let minRecoveryHealth = self.emergencyConfig.minRecoveryHealth
            if let maxDuration = self.emergencyConfig.maxEmergencyDuration {
                let duration = getCurrentBlock().timestamp - (self.emergencyActivatedAt ?? 0.0)
                if duration > maxDuration && health >= minRecoveryHealth {
                    self.clearEmergencyMode()
                    emit EmergencyModeAutoRecovered(poolID: self.poolID, reason: "Max duration exceeded", healthScore: health, duration: duration, timestamp: getCurrentBlock().timestamp)
                    return true
                }
            }
            
            return false
        }
        
        access(contract) fun fundDirectInternal(
            destination: PoolFundingDestination,
            from: @{FungibleToken.Vault},
            sponsor: Address,
            purpose: String,
            metadata: {String: String}
        ) {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Direct funding only in normal state"
                from.getType() == self.config.assetType: "Invalid vault type"
            }
            
            let amount = from.balance
            var policy = self.fundingPolicy
            policy.recordDirectFunding(destination: destination, amount: amount)
            self.fundingPolicy = policy
            
            switch destination {
                case PoolFundingDestination.Lottery:
                    self.lotteryDistributor.fundPrizePool(vault: <- from)
                case PoolFundingDestination.Treasury:
                    self.treasuryDistributor.deposit(vault: <- from)
                case PoolFundingDestination.Savings:
                    self.config.yieldConnector.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                    destroy from
                    self.savingsDistributor.accrueYield(amount: amount)
                    self.totalStaked = self.totalStaked + amount
                    emit SavingsYieldAccrued(poolID: self.poolID, amount: amount)
                default:
                    panic("Unsupported funding destination")
            }
        }
        
        access(all) fun getFundingStats(): {String: UFix64} {
            return {
                "totalDirectLottery": self.fundingPolicy.totalDirectLottery,
                "totalDirectTreasury": self.fundingPolicy.totalDirectTreasury,
                "totalDirectSavings": self.fundingPolicy.totalDirectSavings,
                "maxDirectLottery": self.fundingPolicy.maxDirectLottery ?? 0.0,
                "maxDirectTreasury": self.fundingPolicy.maxDirectTreasury ?? 0.0,
                "maxDirectSavings": self.fundingPolicy.maxDirectSavings ?? 0.0
            }
        }
        
        access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive"
                from.getType() == self.config.assetType: "Invalid vault type"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            switch self.emergencyState {
                case PoolEmergencyState.Normal:
                    assert(from.balance >= self.config.minimumDeposit, message: "Below minimum deposit of ".concat(self.config.minimumDeposit.toString()))
                case PoolEmergencyState.PartialMode:
                    let depositLimit = self.emergencyConfig.partialModeDepositLimit ?? 0.0
                    assert(depositLimit > 0.0, message: "Partial mode deposit limit not configured")
                    assert(from.balance <= depositLimit, message: "Deposit exceeds partial mode limit of ".concat(depositLimit.toString()))
                case PoolEmergencyState.EmergencyMode:
                    panic("Deposits disabled in emergency mode. Withdrawals only.")
                case PoolEmergencyState.Paused:
                    panic("Pool is paused. No operations allowed.")
            }
            
            let amount = from.balance
            self.savingsDistributor.deposit(receiverID: receiverID, amount: amount)
            let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
            self.receiverDeposits[receiverID] = currentPrincipal + amount
            self.totalDeposited = self.totalDeposited + amount
            self.totalStaked = self.totalStaked + amount
            self.config.yieldConnector.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy from
            emit Deposited(poolID: self.poolID, receiverID: receiverID, amount: amount)
        }
        
        access(all) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                amount > 0.0: "Withdrawal amount must be positive"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed")
            
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let _ = self.checkAndAutoRecover()
            }
            
            let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
            assert(totalBalance >= amount, message: "Insufficient balance. You have ".concat(totalBalance.toString()).concat(" but trying to withdraw ").concat(amount.toString()))
            
            let _ = self.savingsDistributor.withdraw(receiverID: receiverID, amount: amount)
            let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
            let interestEarned = totalBalance > currentPrincipal ? totalBalance - currentPrincipal : 0.0
            var principalWithdrawn: UFix64 = 0.0
            var interestWithdrawn: UFix64 = 0.0
            
            if amount <= interestEarned {
                interestWithdrawn = amount
            } else {
                interestWithdrawn = interestEarned
                principalWithdrawn = amount - interestEarned
            }
            
            if principalWithdrawn > 0.0 {
                self.receiverDeposits[receiverID] = currentPrincipal - principalWithdrawn
                self.totalDeposited = self.totalDeposited - principalWithdrawn
            }
            
            var withdrawn <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
            var withdrawalFailed = false
            var amountFromYieldSource: UFix64 = 0.0
            
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let yieldAvailable = self.config.yieldConnector.minimumAvailable()
                if yieldAvailable >= amount {
                    let yieldVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
                    amountFromYieldSource = yieldVault.balance
                    withdrawn.deposit(from: <- yieldVault)
                } else {
                    withdrawalFailed = true
                }
            } else {
                let yieldAvailable = self.config.yieldConnector.minimumAvailable()
                if yieldAvailable >= amount {
                    let yieldVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
                    amountFromYieldSource = yieldVault.balance
                    withdrawn.deposit(from: <- yieldVault)
                } else {
                    withdrawalFailed = true
                }
                
                if withdrawalFailed {
                    self.consecutiveWithdrawFailures = self.consecutiveWithdrawFailures + 1
                    emit WithdrawalFailure(poolID: self.poolID, receiverID: receiverID, amount: amount,
                        consecutiveFailures: self.consecutiveWithdrawFailures, yieldAvailable: yieldAvailable)
                    let _ = self.checkAndAutoTriggerEmergency()
                } else {
                    self.consecutiveWithdrawFailures = 0
                }
            }
            
            if withdrawn.balance < amount {
                let remaining = amount - withdrawn.balance
                assert(
                    self.liquidVault.balance >= remaining, 
                    message: "Insufficient combined liquidity. Yield available: "
                        .concat(withdrawn.balance.toString())
                        .concat(", LiquidVault available: ")
                        .concat(self.liquidVault.balance.toString())
                        .concat(", Remaining needed: ")
                        .concat(remaining.toString())
                )
                withdrawn.deposit(from: <- self.liquidVault.withdraw(amount: remaining))
            }
            
            self.totalStaked = self.totalStaked - amountFromYieldSource
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, amount: amount)
            return <- withdrawn
        }
        
        access(contract) fun processRewards() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let availableYield = yieldBalance > self.totalStaked ? yieldBalance - self.totalStaked : 0.0
            
            if availableYield == 0.0 {
                return
            }
            
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: availableYield)
            
            if plan.savingsAmount > 0.0 {
                self.savingsDistributor.accrueYield(amount: plan.savingsAmount)
                self.totalStaked = self.totalStaked + plan.savingsAmount
                emit SavingsYieldAccrued(poolID: self.poolID, amount: plan.savingsAmount)
            }
            
            // Only withdraw what we actually need to move (lottery + treasury)
            let toWithdraw = plan.lotteryAmount + plan.treasuryAmount
            if toWithdraw > 0.0 {
                let yieldRewards <- self.config.yieldConnector.withdrawAvailable(maxAmount: toWithdraw)
                
                if plan.lotteryAmount > 0.0 {
                    let lotteryVault <- yieldRewards.withdraw(amount: plan.lotteryAmount)
                    self.lotteryDistributor.fundPrizePool(vault: <- lotteryVault)
                    emit LotteryPrizePoolFunded(
                        poolID: self.poolID,
                        amount: plan.lotteryAmount,
                        source: "yield"
                    )
                }
                
                if plan.treasuryAmount > 0.0 {
                    self.treasuryDistributor.deposit(vault: <- yieldRewards)
                    emit TreasuryFunded(
                        poolID: self.poolID,
                        amount: plan.treasuryAmount,
                        source: "yield"
                    )
                } else {
                    destroy yieldRewards
                }
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: availableYield,
                savingsAmount: plan.savingsAmount,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        /// Lottery weights based on principal deposits (O(N) but required for fair lottery)
        access(all) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: ".concat(self.emergencyState.rawValue.toString())
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            if self.checkAndAutoTriggerEmergency() {
                panic("Emergency mode auto-triggered - cannot start draw")
            }
            
            // Lottery weights based on SHARES (not principal)
            // This provides natural time-weighting:
            // - Early depositors bought shares at lower price → more shares
            // - Late depositors buy shares at higher price → fewer shares
            // - Result: earlier deposits have proportionally higher lottery chances
            let timeWeightedStakes: {UInt64: UFix64} = {}
            for receiverID in self.registeredReceivers.keys {
                let shares = self.savingsDistributor.getUserShares(receiverID: receiverID)
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let stake = shares + bonusWeight
                
                if stake > 0.0 {
                    timeWeightedStakes[receiverID] = stake
                }
            }
            
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
                
                let prizeVault <- self.lotteryDistributor.awardPrize(
                    receiverID: winnerID,
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                self.savingsDistributor.deposit(receiverID: winnerID, amount: prizeAmount)
                let currentPrincipal = self.receiverDeposits[winnerID] ?? 0.0
                self.receiverDeposits[winnerID] = currentPrincipal + prizeAmount
                self.totalDeposited = self.totalDeposited + prizeAmount
                self.totalStaked = self.totalStaked + prizeAmount
                self.config.yieldConnector.depositCapacity(from: &prizeVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                destroy prizeVault
                let totalPrizes = self.receiverTotalEarnedPrizes[winnerID] ?? 0.0
                self.receiverTotalEarnedPrizes[winnerID] = totalPrizes + prizeAmount
                
                for nftID in nftIDsForWinner {
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
        
        access(all) fun canDrawNow(): Bool {
            return (getCurrentBlock().timestamp - self.lastDrawTimestamp) >= self.config.drawIntervalSeconds
        }
        
        /// Returns principal deposit (lossless guarantee amount)
        access(all) fun getReceiverDeposit(receiverID: UInt64): UFix64 {
            return self.receiverDeposits[receiverID] ?? 0.0
        }
        
        /// Returns total withdrawable balance (principal + interest)
        access(all) fun getReceiverTotalBalance(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
        }
        
        /// Returns current savings earnings (calculated as totalBalance - deposits)
        /// Note: This now returns current earnings, not historical withdrawn amount
        access(all) fun getReceiverTotalEarnedSavings(receiverID: UInt64): UFix64 {
            return self.getPendingSavingsInterest(receiverID: receiverID)
        }
        
        access(all) fun getReceiverTotalEarnedPrizes(receiverID: UInt64): UFix64 {
            return self.receiverTotalEarnedPrizes[receiverID] ?? 0.0
        }
        
        access(all) fun getPendingSavingsInterest(receiverID: UInt64): UFix64 {
            let principal = self.receiverDeposits[receiverID] ?? 0.0
            let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
            return totalBalance > principal ? totalBalance - principal : 0.0
        }
        
        access(all) fun getUserSavingsShares(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserShares(receiverID: receiverID)
        }
        
        access(all) fun getTotalSavingsShares(): UFix64 {
            return self.savingsDistributor.getTotalShares()
        }
        
        access(all) fun getTotalSavingsAssets(): UFix64 {
            return self.savingsDistributor.getTotalAssets()
        }
        
        access(all) fun getSavingsSharePrice(): UFix64 {
            let totalShares = self.savingsDistributor.getTotalShares()
            let totalAssets = self.savingsDistributor.getTotalAssets()
            return totalShares > 0.0 ? totalAssets / totalShares : 1.0
        }
        
        /// Preview how many shares would be minted for a deposit amount (ERC-4626 style)
        access(all) view fun previewDeposit(amount: UFix64): UFix64 {
            return self.savingsDistributor.convertToShares(amount)
        }
        
        /// Preview how many assets a number of shares is worth (ERC-4626 style)
        access(all) view fun previewRedeem(shares: UFix64): UFix64 {
            return self.savingsDistributor.convertToAssets(shares)
        }
        
        access(all) fun getUserSavingsValue(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
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
        
        access(all) fun getTotalSavingsDistributed(): UFix64 {
            return self.savingsDistributor.getTotalDistributed()
        }
        
        access(all) fun getCurrentReinvestedSavings(): UFix64 {
            if self.totalStaked > self.totalDeposited {
                return self.totalStaked - self.totalDeposited
            }
            return 0.0
        }
        
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
    
    access(all) struct PoolBalance {
        access(all) let deposits: UFix64
        access(all) let totalEarnedPrizes: UFix64
        access(all) let savingsEarned: UFix64
        access(all) let totalBalance: UFix64
        
        init(deposits: UFix64, totalEarnedPrizes: UFix64, savingsEarned: UFix64) {
            self.deposits = deposits
            self.totalEarnedPrizes = totalEarnedPrizes
            self.savingsEarned = savingsEarned
            self.totalBalance = deposits + savingsEarned
        }
    }
    
    access(all) resource interface PoolPositionCollectionPublic {
        access(all) fun getRegisteredPoolIDs(): [UInt64]
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault})
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault}
        access(all) fun getPendingSavingsInterest(poolID: UInt64): UFix64
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
            
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
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
            
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.deposit(from: <- from, receiverID: self.uuid)
        }
        
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeSavings.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid)
        }
        
        access(all) fun getPendingSavingsInterest(poolID: UInt64): UFix64 {
            let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            if poolRef == nil {
                return 0.0
            }
            return poolRef!.getPendingSavingsInterest(receiverID: self.uuid)
        }
        
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            if self.registeredPools[poolID] == nil {
                return PoolBalance(deposits: 0.0, totalEarnedPrizes: 0.0, savingsEarned: 0.0)
            }
            
            let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            if poolRef == nil {
                return PoolBalance(deposits: 0.0, totalEarnedPrizes: 0.0, savingsEarned: 0.0)
            }
            
            return PoolBalance(
                deposits: poolRef!.getReceiverDeposit(receiverID: self.uuid),
                totalEarnedPrizes: poolRef!.getReceiverTotalEarnedPrizes(receiverID: self.uuid),
                savingsEarned: poolRef!.getPendingSavingsInterest(receiverID: self.uuid)
            )
        }
    }
    
    access(contract) fun createPool(
        config: PoolConfig,
        emergencyConfig: EmergencyConfig?,
        fundingPolicy: FundingPolicy?
    ): UInt64 {
        let emptyVault <- DeFiActionsUtils.getEmptyVault(config.assetType)
        let pool <- create Pool(
            config: config, 
            initialVault: <- emptyVault,
            emergencyConfig: emergencyConfig,
            fundingPolicy: fundingPolicy
        )
        
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
    
    access(contract) fun borrowPoolAuth(poolID: UInt64): &Pool? {
        return &self.pools[poolID]
    }
    
    access(all) view fun getAllPoolIDs(): [UInt64] {
        return self.pools.keys
    }
    
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    init() {
        self.PoolPositionCollectionStoragePath = /storage/PrizeSavingsCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeSavingsCollection
        
        self.AdminStoragePath = /storage/PrizeSavingsAdmin
        self.AdminPublicPath = /public/PrizeSavingsAdmin
        
        self.pools <- {}
        self.nextPoolID = 0
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}