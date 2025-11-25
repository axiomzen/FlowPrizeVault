/*
PrizeVaultModular - Prize-Linked Savings Protocol

A no-loss lottery system where users deposit tokens to earn both guaranteed savings 
interest and lottery prizes. Rewards are automatically compounded into deposits.

Architecture:
- Modular yield sources via DeFi Actions interface
- Configurable distribution strategies (savings/lottery/treasury split)
- O(1) gas complexity for interest distribution using accumulator pattern
- Emergency mode with multi-sig support, configurable withdrawal limits, and auto-recovery
- NFT prize support with pending claims system
- Direct funding capabilities for external sponsors
- Batch event emission for scalability (100k+ users)

Core Components:
- SavingsDistributor: Manages proportional interest distribution with O(1) gas
- LotteryDistributor: Prize pool management and winner payouts
- TreasuryDistributor: Protocol reserves, fee collection, and rounding dust
- FundingPolicy: Rate limits and caps for direct funding

Security Features:
- Contract-only authorized pool access (prevents unauthorized manipulation)
- Dust handling to prevent yield source imbalance
- Emergency mode with configurable policies per pool
- Scalable compounding with batch event summaries
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
    
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    
    access(all) event SavingsInterestDistributed(poolID: UInt64, amount: UFix64, interestPerShare: UFix64)
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
    
    /// Emergency configuration for pool safety mechanisms
    /// Authorization and multi-sig are handled at the Flow account level via Admin resource
    access(all) struct EmergencyConfig {
        access(all) let maxEmergencyDuration: UFix64?        // Max time pool can stay in emergency mode
        access(all) let autoRecoveryEnabled: Bool             // Auto-recover to normal after duration
        access(all) let minYieldSourceHealth: UFix64          // Health threshold (0.0-1.0)
        access(all) let maxWithdrawFailures: Int              // Max consecutive withdraw failures before emergency
        access(all) let partialModeDepositLimit: UFix64?      // Max deposit allowed in partial mode
        access(all) let minBalanceThreshold: UFix64           // Min balance as % of totalStaked (0.8-1.0, default 0.95)
        
        init(
            maxEmergencyDuration: UFix64?,
            autoRecoveryEnabled: Bool,
            minYieldSourceHealth: UFix64,
            maxWithdrawFailures: Int,
            partialModeDepositLimit: UFix64?,
            minBalanceThreshold: UFix64
        ) {
            pre {
                minYieldSourceHealth >= 0.0 && minYieldSourceHealth <= 1.0: "Health must be between 0.0 and 1.0"
                maxWithdrawFailures > 0: "Must allow at least 1 withdrawal failure"
                minBalanceThreshold >= 0.8 && minBalanceThreshold <= 1.0: "Balance threshold must be between 0.8 and 1.0"
            }
            self.maxEmergencyDuration = maxEmergencyDuration
            self.autoRecoveryEnabled = autoRecoveryEnabled
            self.minYieldSourceHealth = minYieldSourceHealth
            self.maxWithdrawFailures = maxWithdrawFailures
            self.partialModeDepositLimit = partialModeDepositLimit
            self.minBalanceThreshold = minBalanceThreshold
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
    
    /// Creates default emergency config with reasonable safety limits
    /// Authorization is handled by Admin resource ownership (Flow account level)
    access(all) fun createDefaultEmergencyConfig(): EmergencyConfig {
        return EmergencyConfig(
            maxEmergencyDuration: 86400.0,      // 24 hours
            autoRecoveryEnabled: true,
            minYieldSourceHealth: 0.5,          // 50% health threshold
            maxWithdrawFailures: 3,
            partialModeDepositLimit: 100.0,
            minBalanceThreshold: 0.95           // 95% of totalStaked
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
        
        /// Enable emergency mode for a pool
        /// Authorization is enforced by Admin resource ownership (Flow account multi-sig)
        access(all) fun enableEmergencyMode(poolID: UInt64, reason: String, enabledBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setEmergencyMode(reason: reason)
            emit PoolEmergencyEnabled(poolID: poolID, reason: reason, enabledBy: enabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Disable emergency mode for a pool
        /// Authorization is enforced by Admin resource ownership (Flow account multi-sig)
        access(all) fun disableEmergencyMode(poolID: UInt64, disabledBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.clearEmergencyMode()
            emit PoolEmergencyDisabled(poolID: poolID, disabledBy: disabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Set pool to partial emergency mode (deposits limited, withdrawals work)
        /// Authorization is enforced by Admin resource ownership (Flow account multi-sig)
        access(all) fun setEmergencyPartialMode(poolID: UInt64, reason: String, setBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setPartialMode(reason: reason)
            emit PoolPartialModeEnabled(poolID: poolID, reason: reason, setBy: setBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(all) fun updateEmergencyConfig(poolID: UInt64, newConfig: EmergencyConfig, updatedBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
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
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID) ?? panic("Pool does not exist")
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
        
        // Yield connector immutable per pool for security - create new pool for different yield protocol
        access(all) fun createPool(
            config: PoolConfig,
            emergencyConfig: EmergencyConfig?,
            fundingPolicy: FundingPolicy?,
            createdBy: Address
        ): UInt64 {
            // Use provided configs or create defaults
            let finalEmergencyConfig = emergencyConfig 
                ?? PrizeVaultModular.createDefaultEmergencyConfig()
            let finalFundingPolicy = fundingPolicy 
                ?? PrizeVaultModular.createDefaultFundingPolicy()
            
            let poolID = PrizeVaultModular.createPool(
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
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.processRewards()
        }
        
        access(all) fun setPoolState(poolID: UInt64, state: PoolEmergencyState, reason: String?, setBy: Address) {
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
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
                winnerCount > 0: "Must have at least one winner"
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
        
        access(self) var emergencyState: PoolEmergencyState
        access(self) var emergencyReason: String?
        access(self) var emergencyActivatedAt: UFix64?
        access(self) var emergencyConfig: EmergencyConfig
        access(self) var consecutiveWithdrawFailures: Int
        
        access(self) var fundingPolicy: FundingPolicy
        
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
        access(self) let savingsDistributor: @SavingsDistributor
        access(self) let lotteryDistributor: @LotteryDistributor
        access(self) let treasuryDistributor: @TreasuryDistributor
        
        // Liquid vault and draw state
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
            self.emergencyConfig = emergencyConfig ?? PrizeVaultModular.createDefaultEmergencyConfig()
            self.consecutiveWithdrawFailures = 0
            
            self.fundingPolicy = fundingPolicy ?? PrizeVaultModular.createDefaultFundingPolicy()
            
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
            
            if let maxDuration = self.emergencyConfig.maxEmergencyDuration {
                let duration = getCurrentBlock().timestamp - (self.emergencyActivatedAt ?? 0.0)
                if duration > maxDuration {
                    self.clearEmergencyMode()
                    emit EmergencyModeAutoRecovered(poolID: self.poolID, reason: "Max duration exceeded", healthScore: nil, duration: duration, timestamp: getCurrentBlock().timestamp)
                    return true
                }
            }
            
            let health = self.checkYieldSourceHealth()
            if health >= 0.9 {
                self.clearEmergencyMode()
                emit EmergencyModeAutoRecovered(poolID: self.poolID, reason: "Yield source recovered", healthScore: health, duration: nil, timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            return false
        }
        
        
        /// Distribute savings interest to all users
        /// This is the core savings distribution logic used by both direct funding and process rewards
        /// 
        /// Flow:
        /// 1. Snapshot totalDeposited BEFORE compounding (prevents dilution)
        /// 2. Compound any existing pending interest
        /// 3. Distribute new interest based on snapshot
        /// 4. Compound the newly distributed interest
        /// 5. Send any rounding dust to treasury
        access(contract) fun distributeSavingsInterest(vault: @{FungibleToken.Vault}) {
            let amount = vault.balance
            
            let totalDepositedSnapshot = self.totalDeposited
            
            self.compoundAllPendingSavings()
            
            // Distribute new interest based on snapshot
            let interestPerShare = self.savingsDistributor.distributeInterestAndReinvest(
                vault: <- vault,
                totalDeposited: totalDepositedSnapshot,
                yieldSink: &self.config.yieldConnector as &{DeFiActions.Sink}
            )
            
            // Compound the newly distributed interest (updates totalDeposited and totalStaked)
            let totalCompounded = self.compoundAllPendingSavings()
            
            // Handle rounding dust: send to treasury to prevent yield source imbalance
            if totalCompounded < amount {
                let dust = amount - totalCompounded
                let dustVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: dust)
                self.treasuryDistributor.deposit(vault: <- dustVault)
                
                emit SavingsRoundingDustToTreasury(poolID: self.poolID, amount: dust)
            }
            
            emit SavingsInterestDistributed(poolID: self.poolID, amount: amount, interestPerShare: interestPerShare)
        }
        
        access(contract) fun compoundAllPendingSavings(): UFix64 {
            let receiverIDs = self.getRegisteredReceiverIDs()
            var totalCompounded: UFix64 = 0.0
            var usersCompounded: Int = 0
            
            for receiverID in receiverIDs {
                let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
                if currentDeposit > 0.0 {
                    let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                    
                    if pending > 0.0 {
                        let newDeposit = currentDeposit + pending
                        self.receiverDeposits[receiverID] = newDeposit
                        self.totalDeposited = self.totalDeposited + pending
                        totalCompounded = totalCompounded + pending
                        self.totalStaked = self.totalStaked + pending
                        self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
                        
                        let currentSavings = self.receiverTotalEarnedSavings[receiverID] ?? 0.0
                        self.receiverTotalEarnedSavings[receiverID] = currentSavings + pending
                        
                        usersCompounded = usersCompounded + 1
                    }
                }
            }
            
            if usersCompounded > 0 {
                let avgAmount = totalCompounded / UFix64(usersCompounded)
                emit SavingsInterestCompoundedBatch(
                    poolID: self.poolID,
                    userCount: usersCompounded,
                    totalAmount: totalCompounded,
                    avgAmount: avgAmount
                )
            }
            
            return totalCompounded
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
            self.fundingPolicy.recordDirectFunding(destination: destination, amount: amount)
            
            switch destination {
                case PoolFundingDestination.Lottery:
                    self.lotteryDistributor.fundPrizePool(vault: <- from)
                case PoolFundingDestination.Treasury:
                    self.treasuryDistributor.deposit(vault: <- from)
                case PoolFundingDestination.Savings:
                    self.distributeSavingsInterest(vault: <- from)
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
            let isFirstDeposit = (self.receiverDeposits[receiverID] ?? 0.0) == 0.0
            var pendingCompounded: UFix64 = 0.0
            
            if !isFirstDeposit {
                let currentDeposit = self.receiverDeposits[receiverID]!
                let pending = self.savingsDistributor.claimInterest(receiverID: receiverID, deposit: currentDeposit)
                if pending > 0.0 {
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
                amount > 0.0: "Withdrawal amount must be positive"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed")
            
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                self.checkAndAutoRecover()
            }
            
            let receiverDeposit = self.receiverDeposits[receiverID] ?? 0.0
            assert(receiverDeposit >= amount, message: "Insufficient deposit. You have ".concat(receiverDeposit.toString()).concat(" but trying to withdraw ").concat(amount.toString()))
            
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                log("⚠️  Emergency withdrawal - skipping interest compounding")
            } else {
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
            }
            
            let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
            let newDeposit = currentDeposit - amount
            self.receiverDeposits[receiverID] = newDeposit
            self.totalDeposited = self.totalDeposited - amount
            self.savingsDistributor.updateAfterBalanceChange(receiverID: receiverID, newDeposit: newDeposit)
            
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
                    log("⚠️  Yield source insufficient in emergency, using liquid vault")
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
                    self.checkAndAutoTriggerEmergency()
                } else {
                    self.consecutiveWithdrawFailures = 0
                }
            }
            
            // Use liquid vault if needed
            if withdrawn.balance < amount {
                let remaining = amount - withdrawn.balance
                withdrawn.deposit(from: <- self.liquidVault.withdraw(amount: remaining))
            }
            
            // Only decrease totalStaked by amount withdrawn from yield source (not liquid vault fallback)
            self.totalStaked = self.totalStaked - amountFromYieldSource
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, amount: amount)
            return <- withdrawn
        }
        
        access(all) fun processRewards() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let availableYield = yieldBalance > self.totalStaked ? yieldBalance - self.totalStaked : 0.0
            
            if availableYield == 0.0 {
                return
            }
            
            let yieldRewards <- self.config.yieldConnector.withdrawAvailable(maxAmount: availableYield)
            let totalRewards = yieldRewards.balance
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: totalRewards)
            
            if plan.savingsAmount > 0.0 {
                // Process rewards: collect from yield source, invest and distribute
                let savingsVault <- yieldRewards.withdraw(amount: plan.savingsAmount)
                self.distributeSavingsInterest(vault: <- savingsVault)
            }
            
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
                let treasuryVault <- yieldRewards.withdraw(amount: plan.treasuryAmount)
                self.treasuryDistributor.deposit(vault: <- treasuryVault)
                emit TreasuryFunded(
                    poolID: self.poolID,
                    amount: plan.treasuryAmount,
                    source: "yield"
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
        
        access(all) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: ".concat(self.emergencyState.rawValue.toString())
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            self.checkAndAutoTriggerEmergency()
            
            let timeWeightedStakes: {UInt64: UFix64} = {}
            for receiverID in self.receiverDeposits.keys {
                let deposit = self.receiverDeposits[receiverID]!
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let stake = deposit + bonusWeight
                
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
                
                let prizeVault <- self.lotteryDistributor.awardPrize(
                    receiverID: winnerID,
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                let currentDeposit = self.receiverDeposits[winnerID] ?? 0.0
                let pendingSavings = self.savingsDistributor.claimInterest(receiverID: winnerID, deposit: currentDeposit)
                var newDeposit = currentDeposit
                
                if pendingSavings > 0.0 {
                    newDeposit = newDeposit + pendingSavings
                    self.totalDeposited = self.totalDeposited + pendingSavings
                    self.totalStaked = self.totalStaked + pendingSavings
                    
                    let currentSavings = self.receiverTotalEarnedSavings[winnerID] ?? 0.0
                    self.receiverTotalEarnedSavings[winnerID] = currentSavings + pendingSavings
                }
                
                newDeposit = newDeposit + prizeAmount
                self.receiverDeposits[winnerID] = newDeposit
                self.totalDeposited = self.totalDeposited + prizeAmount
                self.totalStaked = self.totalStaked + prizeAmount
                self.savingsDistributor.updateAfterBalanceChange(receiverID: winnerID, newDeposit: newDeposit)
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
                    
                    // Store as pending claim - winner claims via separate transaction
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
    
    /// Returns authorized pool reference - restricted to contract only for security
    /// Only Admin resource and internal contract functions can access this
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
