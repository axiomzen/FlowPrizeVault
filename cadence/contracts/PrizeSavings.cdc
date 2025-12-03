/*
PrizeSavings - Prize-Linked Savings Protocol

No-loss lottery where users deposit tokens to earn guaranteed savings interest and lottery prizes.
Rewards auto-compound into deposits via ERC4626-style shares model.

Architecture:
- ERC4626-style shares for O(1) interest distribution
- TWAB (time-weighted average balance) for fair lottery weighting
- On-chain randomness via Flow's RandomConsumer
- Modular yield sources via DeFi Actions interface
- Configurable distribution strategies (savings/lottery/treasury split)
- Pluggable winner selection (weighted single, multi-winner, fixed tiers)
- Emergency mode with auto-recovery and health monitoring
- NFT prize support with pending claims
- Direct funding for external sponsors
- Bonus lottery weights for promotions
- Winner tracking integration for leaderboards

Core Components:
- SavingsDistributor: Shares vault with epoch-based stake tracking
- LotteryDistributor: Prize pool, NFT prizes, and draw execution
- Pool: Deposits, withdrawals, yield processing, and prize draws
- Treasury: Auto-forwards to configured recipient during reward processing
*/

import "FungibleToken"
import "NonFungibleToken"
import "RandomConsumer"
import "DeFiActions"
import "DeFiActionsUtils"
import "PrizeWinnerTracker"
import "Xorshift128plus"

access(all) contract PrizeSavings {
    access(all) entitlement ConfigOps
    access(all) entitlement CriticalOps
    access(all) entitlement OwnerOnly
    
    /// Virtual offset constants for ERC4626 inflation attack protection.
    /// These create "dead" shares/assets that prevent share price manipulation.
    /// Using 1.0 as the offset value (standard practice).
    access(all) let VIRTUAL_SHARES: UFix64
    access(all) let VIRTUAL_ASSETS: UFix64
    
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, requestedAmount: UFix64, actualAmount: UFix64)
    
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    
    access(all) event SavingsYieldAccrued(poolID: UInt64, amount: UFix64)
    access(all) event SavingsInterestCompounded(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event SavingsInterestCompoundedBatch(poolID: UInt64, userCount: Int, totalAmount: UFix64, avgAmount: UFix64)
    access(all) event SavingsRoundingDustToTreasury(poolID: UInt64, amount: UFix64)
    
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    access(all) event LotteryPrizePoolFunded(poolID: UInt64, amount: UFix64, source: String)
    access(all) event NewEpochStarted(poolID: UInt64, epochID: UInt64, startTime: UFix64)
    
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, updatedBy: Address)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, updatedBy: Address)
    access(all) event DrawIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, updatedBy: Address)
    access(all) event MinimumDepositUpdated(poolID: UInt64, oldMinimum: UFix64, newMinimum: UFix64, updatedBy: Address)
    access(all) event PoolCreatedByAdmin(poolID: UInt64, assetType: String, strategy: String, createdBy: Address)
    
    access(all) event PoolPaused(poolID: UInt64, pausedBy: Address, reason: String)
    access(all) event PoolUnpaused(poolID: UInt64, unpausedBy: Address)
    access(all) event TreasuryFunded(poolID: UInt64, amount: UFix64, source: String)
    access(all) event TreasuryRecipientUpdated(poolID: UInt64, newRecipient: Address?, updatedBy: Address)
    access(all) event TreasuryForwarded(poolID: UInt64, amount: UFix64, recipient: Address)
    
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
        access(all) let maxDirectSavings: UFix64?
        access(all) var totalDirectLottery: UFix64
        access(all) var totalDirectSavings: UFix64
        
        init(maxDirectLottery: UFix64?, maxDirectSavings: UFix64?) {
            self.maxDirectLottery = maxDirectLottery
            self.maxDirectSavings = maxDirectSavings
            self.totalDirectLottery = 0.0
            self.totalDirectSavings = 0.0
        }
        
        access(contract) fun recordDirectFunding(destination: PoolFundingDestination, amount: UFix64) {
            switch destination {
                case PoolFundingDestination.Lottery:
                    self.totalDirectLottery = self.totalDirectLottery + amount
                    if self.maxDirectLottery != nil {
                        assert(self.totalDirectLottery <= self.maxDirectLottery!, message: "Direct lottery funding limit exceeded")
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
            maxDirectSavings: nil
        )
    }
    
    access(all) resource Admin {
        access(contract) init() {}

        access(CriticalOps) fun updatePoolDistributionStrategy(
            poolID: UInt64,
            newStrategy: {DistributionStrategy},
            updatedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(CriticalOps) fun updatePoolWinnerSelectionStrategy(
            poolID: UInt64,
            newStrategy: {WinnerSelectionStrategy},
            updatedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(ConfigOps) fun updatePoolWinnerTracker(
            poolID: UInt64,
            newTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?,
            updatedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(ConfigOps) fun updatePoolDrawInterval(
            poolID: UInt64,
            newInterval: UFix64,
            updatedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(ConfigOps) fun updatePoolMinimumDeposit(
            poolID: UInt64,
            newMinimum: UFix64,
            updatedBy: Address
        ) {
            pre {
                newMinimum >= 0.0: "Minimum deposit cannot be negative"
            }
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(CriticalOps) fun enableEmergencyMode(poolID: UInt64, reason: String, enabledBy: Address) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setEmergencyMode(reason: reason)
            emit PoolEmergencyEnabled(poolID: poolID, reason: reason, enabledBy: enabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(CriticalOps) fun disableEmergencyMode(poolID: UInt64, disabledBy: Address) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.clearEmergencyMode()
            emit PoolEmergencyDisabled(poolID: poolID, disabledBy: disabledBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(CriticalOps) fun setEmergencyPartialMode(poolID: UInt64, reason: String, setBy: Address) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setPartialMode(reason: reason)
            emit PoolPartialModeEnabled(poolID: poolID, reason: reason, setBy: setBy, timestamp: getCurrentBlock().timestamp)
        }
        
        access(CriticalOps) fun updateEmergencyConfig(poolID: UInt64, newConfig: EmergencyConfig, updatedBy: Address) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.setEmergencyConfig(config: newConfig)
            emit EmergencyConfigUpdated(poolID: poolID, updatedBy: updatedBy)
        }
        
        access(CriticalOps) fun fundPoolDirect(
            poolID: UInt64,
            destination: PoolFundingDestination,
            from: @{FungibleToken.Vault},
            sponsor: Address,
            purpose: String,
            metadata: {String: String}?
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
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
                default: return "Unknown"
            }
        }
        
        access(CriticalOps) fun createPool(
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
        
        access(ConfigOps) fun processPoolRewards(poolID: UInt64) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.processRewards()
        }
        
        access(CriticalOps) fun setPoolState(poolID: UInt64, state: PoolEmergencyState, reason: String?, setBy: Address) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        /// Set the treasury recipient for automatic forwarding.
        /// Once set, treasury funds are auto-forwarded during processRewards().
        /// Pass nil to disable auto-forwarding (funds stored in distributor).
        /// 
        /// SECURITY: Requires OwnerOnly entitlement - NEVER issue capabilities with this.
        /// Only the account owner (via direct storage borrow with auth) can call this.
        /// For multi-sig protection, store Admin in a multi-sig account.
        access(OwnerOnly) fun setPoolTreasuryRecipient(
            poolID: UInt64,
            recipientCap: Capability<&{FungibleToken.Receiver}>?,
            updatedBy: Address
        ) {
            pre {
                recipientCap == nil || recipientCap!.check(): "Treasury recipient capability must be valid"
            }
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setTreasuryRecipient(cap: recipientCap)
            
            emit TreasuryRecipientUpdated(
                poolID: poolID,
                newRecipient: recipientCap?.address,
                updatedBy: updatedBy
            )
        }
        
        access(ConfigOps) fun setBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            bonusWeight: UFix64,
            reason: String,
            setBy: Address
        ) {
            pre {
                bonusWeight >= 0.0: "Bonus weight cannot be negative"
            }
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.setBonusWeight(receiverID: receiverID, bonusWeight: bonusWeight, reason: reason, setBy: setBy)
        }
        
        access(ConfigOps) fun addBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            additionalWeight: UFix64,
            reason: String,
            addedBy: Address
        ) {
            pre {
                additionalWeight > 0.0: "Additional weight must be positive"
            }
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.addBonusWeight(receiverID: receiverID, additionalWeight: additionalWeight, reason: reason, addedBy: addedBy)
        }
        
        access(ConfigOps) fun removeBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            removedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.removeBonusWeight(receiverID: receiverID, removedBy: removedBy)
        }
        
        access(ConfigOps) fun depositNFTPrize(
            poolID: UInt64,
            nft: @{NonFungibleToken.NFT},
            depositedBy: Address
        ) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        access(ConfigOps) fun withdrawNFTPrize(
            poolID: UInt64,
            nftID: UInt64,
            withdrawnBy: Address
        ): @{NonFungibleToken.NFT} {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
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
        
        // Batch draw functions (for future scalability when user count grows)
        
        access(CriticalOps) fun startPoolDrawSnapshot(poolID: UInt64) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.startDrawSnapshot()
        }
        
        access(CriticalOps) fun processPoolDrawBatch(poolID: UInt64, limit: Int) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.captureStakesBatch(limit: limit)
        }
        
        access(CriticalOps) fun finalizePoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID) ?? panic("Pool does not exist")
            poolRef.finalizeDrawStart()
        }
        
    }
    
    access(all) let AdminStoragePath: StoragePath
    
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
        
        /// Note: Percentages must sum to exactly 1.0 (strict equality).
        /// Use values like 0.4, 0.4, 0.2 - not repeating decimals like 0.33333333.
        /// If using thirds, use 0.33, 0.33, 0.34 to sum exactly to 1.0.
        init(savings: UFix64, lottery: UFix64, treasury: UFix64) {
            pre {
                savings + lottery + treasury == 1.0: "Percentages must sum to exactly 1.0 (e.g., 0.4 + 0.4 + 0.2)"
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
    /// 
    /// Security: Uses virtual offset pattern to prevent ERC4626 "inflation attack".
    /// While current yieldConnector implementations (FlowVaultsConnector) use private Tides
    /// that can't receive external deposits, the virtual offset provides defense-in-depth
    /// against future connectors that might be permissionless.
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
        
        /// Time-weighted stake tracking
        access(self) let userCumulativeShareSeconds: {UInt64: UFix64}
        access(self) let userLastUpdateTime: {UInt64: UFix64}
        access(self) let userEpochID: {UInt64: UInt64}
        access(self) var currentEpochID: UInt64
        access(self) var epochStartTime: UFix64
        
        init(vaultType: Type) {
            self.totalShares = 0.0
            self.totalAssets = 0.0
            self.userShares = {}
            self.totalDistributed = 0.0
            self.vaultType = vaultType
            
            self.userCumulativeShareSeconds = {}
            self.userLastUpdateTime = {}
            self.userEpochID = {}
            self.currentEpochID = 1
            self.epochStartTime = getCurrentBlock().timestamp
        }
        
        access(contract) fun accrueYield(amount: UFix64) {
            if amount == 0.0 || self.totalShares == 0.0 {
                return
            }
            
            self.totalAssets = self.totalAssets + amount
            self.totalDistributed = self.totalDistributed + amount
        }
        
        access(all) view fun getElapsedShareSeconds(receiverID: UInt64): UFix64 {
            let now = getCurrentBlock().timestamp
            let userEpoch = self.userEpochID[receiverID] ?? 0
            let currentShares = self.userShares[receiverID] ?? 0.0
            
            // If epoch is stale, calculate from epoch start (as if reset happened)
            let effectiveLastUpdate = userEpoch < self.currentEpochID 
                ? self.epochStartTime 
                : (self.userLastUpdateTime[receiverID] ?? self.epochStartTime)
            
            let elapsed = now - effectiveLastUpdate
            if elapsed <= 0.0 {
                return 0.0
            }
            return currentShares * elapsed
        }
        
        access(all) view fun getEffectiveAccumulated(receiverID: UInt64): UFix64 {
            let userEpoch = self.userEpochID[receiverID] ?? 0
            if userEpoch < self.currentEpochID {
                return 0.0  // Would be reset on next accumulation
            }
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        access(contract) fun accumulateTime(receiverID: UInt64) {
            let userEpoch = self.userEpochID[receiverID] ?? 0
            
            // Lazy reset for stale epoch
            if userEpoch < self.currentEpochID {
                self.userCumulativeShareSeconds[receiverID] = 0.0
                self.userLastUpdateTime[receiverID] = self.epochStartTime
                self.userEpochID[receiverID] = self.currentEpochID
            }
            
            // Get elapsed share-seconds and add to accumulated
            let elapsed = self.getElapsedShareSeconds(receiverID: receiverID)
            if elapsed > 0.0 {
                let currentAccum = self.userCumulativeShareSeconds[receiverID] ?? 0.0
                self.userCumulativeShareSeconds[receiverID] = currentAccum + elapsed
                self.userLastUpdateTime[receiverID] = getCurrentBlock().timestamp
            }
        }
        
        access(all) view fun getTimeWeightedStake(receiverID: UInt64): UFix64 {
            return self.getEffectiveAccumulated(receiverID: receiverID) 
                + self.getElapsedShareSeconds(receiverID: receiverID)
        }
        
        access(contract) fun updateAndGetTimeWeightedStake(receiverID: UInt64): UFix64 {
            self.accumulateTime(receiverID: receiverID)
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        access(contract) fun startNewPeriod() {
            self.currentEpochID = self.currentEpochID + 1
            self.epochStartTime = getCurrentBlock().timestamp
        }
        
        access(all) view fun getCurrentEpochID(): UInt64 {
            return self.currentEpochID
        }
        
        access(all) view fun getEpochStartTime(): UFix64 {
            return self.epochStartTime
        }
        
        access(contract) fun deposit(receiverID: UInt64, amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            self.accumulateTime(receiverID: receiverID)
            
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
            
            self.accumulateTime(receiverID: receiverID)
            
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
            // Virtual offset: (assets * (totalShares + 1)) / (totalAssets + 1)
            // This prevents inflation attacks by ensuring share price starts near 1:1
            // and can't be manipulated by donations when totalShares is small
            let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
            let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS
            
            if assets > 0.0 {
                let maxSafeAssets = UFix64.max / effectiveShares
                assert(assets <= maxSafeAssets, message: "Deposit amount too large - would cause overflow")
            }
            
            return (assets * effectiveShares) / effectiveAssets
        }
        
        access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
            // Virtual offset: (shares * (totalAssets + 1)) / (totalShares + 1)
            let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
            let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS
            
            if shares > 0.0 {
                let maxSafeShares = UFix64.max / effectiveAssets
                assert(shares <= maxSafeShares, message: "Share amount too large - would cause overflow")
            }
            
            return (shares * effectiveAssets) / effectiveShares
        }
        
        access(all) view fun getUserAssetValue(receiverID: UInt64): UFix64 {
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            return self.convertToAssets(userShareBalance)
        }
        
        access(all) view fun getTotalDistributed(): UFix64 {
            return self.totalDistributed
        }
        
        access(all) view fun getTotalShares(): UFix64 {
            return self.totalShares
        }
        
        access(all) view fun getTotalAssets(): UFix64 {
            return self.totalAssets
        }
        
        access(all) view fun getUserShares(receiverID: UInt64): UFix64 {
            return self.userShares[receiverID] ?? 0.0
        }
        
        access(all) view fun getUserAccumulatedRaw(receiverID: UInt64): UFix64 {
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        access(all) view fun getUserLastUpdateTime(receiverID: UInt64): UFix64 {
            return self.userLastUpdateTime[receiverID] ?? self.epochStartTime
        }
        
        access(all) view fun getUserEpochID(receiverID: UInt64): UInt64 {
            return self.userEpochID[receiverID] ?? 0
        }
        
        /// Calculate projected stake at a specific time (no state change)
        access(all) view fun calculateStakeAtTime(receiverID: UInt64, targetTime: UFix64): UFix64 {
            let userEpoch = self.userEpochID[receiverID] ?? 0
            let shares = self.userShares[receiverID] ?? 0.0
            
            if userEpoch < self.currentEpochID {
                if targetTime <= self.epochStartTime { return 0.0 }
                return shares * (targetTime - self.epochStartTime)
            }
            
            let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.epochStartTime
            let accumulated = self.userCumulativeShareSeconds[receiverID] ?? 0.0
            
            if targetTime <= lastUpdate {
                let overdraft = lastUpdate - targetTime
                let overdraftAmount = shares * overdraft
                return accumulated >= overdraftAmount ? accumulated - overdraftAmount : 0.0
            }
            
            return accumulated + (shares * (targetTime - lastUpdate))
        }
    }
    
    access(all) resource LotteryDistributor {
        access(self) var prizeVault: @{FungibleToken.Vault}
        access(self) var nftPrizeSavings: @{UInt64: {NonFungibleToken.NFT}}
        access(self) var pendingNFTClaims: @{UInt64: [{NonFungibleToken.NFT}]}
        access(self) var _prizeRound: UInt64
        access(all) var totalPrizesDistributed: UFix64
        
        access(all) view fun getPrizeRound(): UInt64 {
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
        
        access(all) view fun getPrizePoolBalance(): UFix64 {
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
        
        access(all) view fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.pendingNFTClaims[receiverID]?.length ?? 0
        }
        
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            let nfts = &self.pendingNFTClaims[receiverID] as &[{NonFungibleToken.NFT}]?
            if nfts == nil {
                return []
            }
            
            var ids: [UInt64] = []
            for nft in nfts! {
                ids.append(nft.uuid)
            }
            return ids
        }
        
        access(all) view fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.nftPrizeSavings.keys
        }
        
        access(all) view fun borrowNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
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
        /// Constants for random number scaling in winner selection
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        
        access(all) let nftIDs: [UInt64]
        
        init(nftIDs: [UInt64]) {
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
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
            
            let scaledRandom = UFix64(randomNumber % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
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
        /// Constants for random number scaling in winner selection
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        access(all) let winnerCount: Int
        access(all) let prizeSplits: [UFix64]
        access(all) let nftIDsPerWinner: [[UInt64]]
        
        /// nftIDs: flat array of NFT IDs to distribute (one per winner, in order)
        init(winnerCount: Int, prizeSplits: [UFix64], nftIDs: [UInt64]) {
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
            
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
            self.winnerCount = winnerCount
            self.prizeSplits = prizeSplits
            
            var nftArray: [[UInt64]] = []
            var nftIndex = 0
            var winnerIdx = 0
            while winnerIdx < winnerCount {
                if nftIndex < nftIDs.length {
                    nftArray.append([nftIDs[nftIndex]])
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
                    let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
                    let randomValue = scaledRandom * remainingTotal
                
                var selectedIdx = 0
                for i, cumSum in remainingCumSum {
                    if randomValue < cumSum {
                        selectedIdx = i
                        break
                    }
                }
                
                selectedWinners.append(remainingIDs[selectedIdx])
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
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        
        access(all) let tiers: [PrizeTier]
        
        init(tiers: [PrizeTier]) {
            pre {
                tiers.length > 0: "Must have at least one prize tier"
            }
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
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
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            for tier in self.tiers {
                var tierWinnerCount = 0
                
                while tierWinnerCount < tier.winnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    let rng = prg.nextUInt64()
                    let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
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
    
    /// Batch draw state for breaking startDraw() into multiple transactions.
    /// Flow: startDrawSnapshot() → captureStakesBatch() (repeat) → finalizeDrawStart()
    access(all) struct BatchDrawState {
        access(all) let drawCutoffTime: UFix64
        access(all) let previousEpochStartTime: UFix64  // Store epoch start time before startNewPeriod()
        access(all) var capturedWeights: {UInt64: UFix64}
        access(all) var totalWeight: UFix64
        access(all) var processedCount: Int
        access(all) let snapshotEpochID: UInt64
        
        init(cutoffTime: UFix64, epochStartTime: UFix64, epochID: UInt64) {
            self.drawCutoffTime = cutoffTime
            self.previousEpochStartTime = epochStartTime
            self.capturedWeights = {}
            self.totalWeight = 0.0
            self.processedCount = 0
            self.snapshotEpochID = epochID
        }
    }
    
    /// Pool contains nested resources (SavingsDistributor, LotteryDistributor)
    /// that hold FungibleToken vaults and NFTs. In Cadence 1.0+, these are automatically
    /// destroyed when the Pool is destroyed. The destroy order is:
    /// 1. pendingDrawReceipt (RandomConsumer.Request)
    /// 2. randomConsumer
    /// 3. savingsDistributor (contains user share data)
    /// 4. lotteryDistributor (contains prizeVault, nftPrizeSavings, pendingNFTClaims)
    /// Treasury is auto-forwarded to configured recipient during processRewards().
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
        access(all) var lastDrawTimestamp: UFix64
        access(all) var pendingLotteryYield: UFix64  // Lottery funds still earning in yield source
        access(all) var totalTreasuryForwarded: UFix64  // Total treasury auto-forwarded to recipient
        access(self) var treasuryRecipientCap: Capability<&{FungibleToken.Receiver}>?  // Auto-forward treasury to this address
        access(self) let savingsDistributor: @SavingsDistributor
        access(self) let lotteryDistributor: @LotteryDistributor
        
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        /// Batch draw state. When set, deposits/withdrawals are locked.
        access(self) var batchDrawState: BatchDrawState?
        
        init(
            config: PoolConfig, 
            emergencyConfig: EmergencyConfig?,
            fundingPolicy: FundingPolicy?
        ) {
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
            self.registeredReceivers = {}
            self.receiverBonusWeights = {}
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lastDrawTimestamp = 0.0
            self.pendingLotteryYield = 0.0
            self.totalTreasuryForwarded = 0.0
            self.treasuryRecipientCap = nil
            
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            self.batchDrawState = nil
        }
        
        /// Register a receiver ID. Only callable within contract (by PoolPositionCollection).
        access(contract) fun registerReceiver(receiverID: UInt64) {
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
                    "maxDuration": self.emergencyConfig.maxEmergencyDuration ?? 0.0  // 0.0 = no max
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
                case PoolFundingDestination.Savings:
                    // Prevent orphaned funds: savings distribution requires depositors
                    assert(
                        self.savingsDistributor.getTotalShares() > 0.0,
                        message: "Cannot fund savings with no depositors - funds would be orphaned"
                    )
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
                "totalDirectSavings": self.fundingPolicy.totalDirectSavings,
                "maxDirectLottery": self.fundingPolicy.maxDirectLottery ?? 0.0,
                "maxDirectSavings": self.fundingPolicy.maxDirectSavings ?? 0.0
            }
        }
        
        /// Deposit funds for a receiver. Only callable within contract (by PoolPositionCollection).
        access(contract) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive"
                from.getType() == self.config.assetType: "Invalid vault type"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            // TODO: Future batch draw support - add check here:
            // assert(self.batchDrawState == nil, message: "Deposits locked during batch draw processing")
            
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
            
            // Process pending yield before minting shares to prevent diluting existing users
            if self.getAvailableYieldRewards() > 0.0 {
                self.processRewards()
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
        
        /// Withdraw funds for a receiver. Only callable within contract (by PoolPositionCollection).
        access(contract) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                amount > 0.0: "Withdrawal amount must be positive"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            // TODO: Future batch draw support - add check here:
            // assert(self.batchDrawState == nil, message: "Withdrawals locked during batch draw processing")
            
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed")
            
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let _ = self.checkAndAutoRecover()
            }
            
            // Process pending yield so withdrawing user gets their fair share
            if self.emergencyState == PoolEmergencyState.Normal && self.getAvailableYieldRewards() > 0.0 {
                self.processRewards()
            }
            
            let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
            assert(totalBalance >= amount, message: "Insufficient balance. You have ".concat(totalBalance.toString()).concat(" but trying to withdraw ").concat(amount.toString()))
            
            // 1. Check yield source availability BEFORE any state changes
            let yieldAvailable = self.config.yieldConnector.minimumAvailable()
            
            if yieldAvailable < amount {
                // Insufficient liquidity - always emit failure event for visibility
                let newFailureCount: Int = self.emergencyState == PoolEmergencyState.Normal 
                    ? self.consecutiveWithdrawFailures + 1 
                    : self.consecutiveWithdrawFailures
                
                emit WithdrawalFailure(
                    poolID: self.poolID, 
                    receiverID: receiverID, 
                    amount: amount,
                    consecutiveFailures: newFailureCount, 
                    yieldAvailable: yieldAvailable
                )
                
                // Only increment counter and check emergency trigger in Normal mode
                if self.emergencyState == PoolEmergencyState.Normal {
                    self.consecutiveWithdrawFailures = newFailureCount
                    let _ = self.checkAndAutoTriggerEmergency()
                }
                
                emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: 0.0)
                return <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
            }
            
            // 2. Withdraw from yield source
            let withdrawn <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
            let actualWithdrawn = withdrawn.balance
            
            // 3. Handle unexpected zero withdrawal (yield source failed between check and withdraw)
            if actualWithdrawn == 0.0 {
                let newFailureCount: Int = self.emergencyState == PoolEmergencyState.Normal 
                    ? self.consecutiveWithdrawFailures + 1 
                    : self.consecutiveWithdrawFailures
                
                emit WithdrawalFailure(
                    poolID: self.poolID, 
                    receiverID: receiverID, 
                    amount: amount,
                    consecutiveFailures: newFailureCount, 
                    yieldAvailable: yieldAvailable
                )
                
                if self.emergencyState == PoolEmergencyState.Normal {
                    self.consecutiveWithdrawFailures = newFailureCount
                    let _ = self.checkAndAutoTriggerEmergency()
                }
                
                emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: 0.0)
                return <- withdrawn
            }
            
            // Reset failure counter on success (normal mode only)
            if self.emergencyState == PoolEmergencyState.Normal {
                self.consecutiveWithdrawFailures = 0
            }
            
            // 4. Burn shares for actual amount withdrawn
            let _ = self.savingsDistributor.withdraw(receiverID: receiverID, amount: actualWithdrawn)
            
            // 5. Update principal/interest tracking
            let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
            let interestEarned: UFix64 = totalBalance > currentPrincipal ? totalBalance - currentPrincipal : 0.0
            let principalWithdrawn: UFix64 = actualWithdrawn > interestEarned ? actualWithdrawn - interestEarned : 0.0
            
            if principalWithdrawn > 0.0 {
                self.receiverDeposits[receiverID] = currentPrincipal - principalWithdrawn
                self.totalDeposited = self.totalDeposited - principalWithdrawn
            }
            
            self.totalStaked = self.totalStaked - actualWithdrawn
            
            // Emit with both requested and actual amounts (partial withdrawal visible when they differ)
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: actualWithdrawn)
            return <- withdrawn
        }
        
        access(contract) fun processRewards() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            
            // CRITICAL: Exclude funds already allocated but still in yield source
            // - totalStaked: user deposits + reinvested savings
            // - pendingLotteryYield: lottery funds waiting for next draw
            let allocatedFunds = self.totalStaked + self.pendingLotteryYield
            let availableYield: UFix64 = yieldBalance > allocatedFunds ? yieldBalance - allocatedFunds : 0.0
            
            if availableYield == 0.0 {
                return
            }
            
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: availableYield)
            
            if plan.savingsAmount > 0.0 {
                self.savingsDistributor.accrueYield(amount: plan.savingsAmount)
                self.totalStaked = self.totalStaked + plan.savingsAmount
                emit SavingsYieldAccrued(poolID: self.poolID, amount: plan.savingsAmount)
            }
            
            // Lottery funds stay in yield source to keep earning - only track virtually
            if plan.lotteryAmount > 0.0 {
                self.pendingLotteryYield = self.pendingLotteryYield + plan.lotteryAmount
                emit LotteryPrizePoolFunded(
                    poolID: self.poolID,
                    amount: plan.lotteryAmount,
                    source: "yield_pending"
                )
            }
            
            // Treasury: withdraw and forward if recipient is configured and valid
            // If no recipient, skip - treasury allocation stays in yield source as future yield
            if plan.treasuryAmount > 0.0 {
                if let cap = self.treasuryRecipientCap {
                    if let recipientRef = cap.borrow() {
                        let treasuryVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: plan.treasuryAmount)
                        let actualAmount = treasuryVault.balance
                        if actualAmount > 0.0 {
                            recipientRef.deposit(from: <- treasuryVault)
                            self.totalTreasuryForwarded = self.totalTreasuryForwarded + actualAmount
                            emit TreasuryForwarded(
                                poolID: self.poolID,
                                amount: actualAmount,
                                recipient: cap.address
                            )
                        } else {
                            destroy treasuryVault
                        }
                    }
                }
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: availableYield,
                savingsAmount: plan.savingsAmount,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        /// Start draw using time-weighted stakes (TWAB-like). See docs/LOTTERY_FAIRNESS_ANALYSIS.md
        access(all) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: ".concat(self.emergencyState.rawValue.toString())
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            if self.checkAndAutoTriggerEmergency() {
                panic("Emergency mode auto-triggered - cannot start draw")
            }
            
            let timeWeightedStakes: {UInt64: UFix64} = {}
            for receiverID in self.registeredReceivers.keys {
                let twabStake = self.savingsDistributor.updateAndGetTimeWeightedStake(receiverID: receiverID)
                
                // Scale bonus weights by epoch duration
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let epochDuration = getCurrentBlock().timestamp - self.savingsDistributor.getEpochStartTime()
                let scaledBonus = bonusWeight * epochDuration
                
                let totalStake = twabStake + scaledBonus
                if totalStake > 0.0 {
                    timeWeightedStakes[receiverID] = totalStake
                }
            }
            
            // Start new epoch immediately after snapshot (zero gap)
            self.savingsDistributor.startNewPeriod()
            emit NewEpochStarted(
                poolID: self.poolID,
                epochID: self.savingsDistributor.getCurrentEpochID(),
                startTime: self.savingsDistributor.getEpochStartTime()
            )
            
            // Materialize pending lottery funds from yield source
            if self.pendingLotteryYield > 0.0 {
                let lotteryVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: self.pendingLotteryYield)
                let actualWithdrawn = lotteryVault.balance
                self.lotteryDistributor.fundPrizePool(vault: <- lotteryVault)
                self.pendingLotteryYield = self.pendingLotteryYield - actualWithdrawn
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
        
        // Batch draw: breaks startDraw() into multiple transactions for scalability
        // Flow: startDrawSnapshot() → captureStakesBatch() (repeat) → finalizeDrawStart()
        
        /// Step 1: Lock the pool and take time snapshot (not yet implemented)
        access(CriticalOps) fun startDrawSnapshot() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled"
                self.batchDrawState == nil: "Draw already in progress"
                self.pendingDrawReceipt == nil: "Receipt exists"
            }
            panic("Batch draw not yet implemented")
        }
        
        /// Step 2: Calculate stakes for a batch of users (not yet implemented)
        access(CriticalOps) fun captureStakesBatch(limit: Int) {
            pre {
                self.batchDrawState != nil: "No batch draw active"
            }
            panic("Batch draw not yet implemented")
        }
        
        /// Step 3: Request randomness after all batches processed (not yet implemented)
        access(CriticalOps) fun finalizeDrawStart() {
            pre {
                self.batchDrawState != nil: "No batch draw active"
                self.batchDrawState!.processedCount >= self.registeredReceivers.keys.length: "Batch processing not complete"
            }
            panic("Batch draw not yet implemented")
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
        
        access(all) view fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.lotteryDistributor.getPendingNFTCount(receiverID: receiverID)
        }
        
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            return self.lotteryDistributor.getPendingNFTIDs(receiverID: receiverID)
        }
        
        /// Claim pending NFT prize. Only callable within contract (by PoolPositionCollection).
        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
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
        access(all) view fun getReceiverDeposit(receiverID: UInt64): UFix64 {
            return self.receiverDeposits[receiverID] ?? 0.0
        }
        
        /// Returns total withdrawable balance (principal + interest)
        access(all) view fun getReceiverTotalBalance(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
        }
        
        /// Returns lifetime total lottery prizes earned by this receiver.
        /// This is a cumulative counter that increases when prizes are won.
        access(all) view fun getReceiverTotalEarnedPrizes(receiverID: UInt64): UFix64 {
            return self.receiverTotalEarnedPrizes[receiverID] ?? 0.0
        }
        
        /// Returns current pending savings interest (not yet withdrawn).
        /// This is NOT lifetime total - it's the current accrued interest that
        /// will be included in the next withdrawal.
        /// Formula: totalBalance - principal deposits
        access(all) view fun getPendingSavingsInterest(receiverID: UInt64): UFix64 {
            let principal = self.receiverDeposits[receiverID] ?? 0.0
            let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
            return totalBalance > principal ? totalBalance - principal : 0.0
        }
        
        access(all) view fun getUserSavingsShares(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserShares(receiverID: receiverID)
        }
        
        access(all) view fun getTotalSavingsShares(): UFix64 {
            return self.savingsDistributor.getTotalShares()
        }
        
        access(all) view fun getTotalSavingsAssets(): UFix64 {
            return self.savingsDistributor.getTotalAssets()
        }
        
        access(all) view fun getSavingsSharePrice(): UFix64 {
            let totalShares = self.savingsDistributor.getTotalShares()
            let totalAssets = self.savingsDistributor.getTotalAssets()
            return totalShares > 0.0 ? totalAssets / totalShares : 1.0
        }
        
        access(all) view fun getUserTimeWeightedStake(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getTimeWeightedStake(receiverID: receiverID)
        }
        
        access(all) view fun getCurrentEpochID(): UInt64 {
            return self.savingsDistributor.getCurrentEpochID()
        }
        
        access(all) view fun getEpochStartTime(): UFix64 {
            return self.savingsDistributor.getEpochStartTime()
        }
        
        access(all) view fun getEpochElapsedTime(): UFix64 {
            return getCurrentBlock().timestamp - self.savingsDistributor.getEpochStartTime()
        }
        
        /// Batch draw support
        access(all) view fun isBatchDrawInProgress(): Bool {
            return self.batchDrawState != nil
        }
        
        access(all) view fun getBatchDrawProgress(): {String: AnyStruct}? {
            if let state = self.batchDrawState {
                return {
                    "cutoffTime": state.drawCutoffTime,
                    "totalWeight": state.totalWeight,
                    "processedCount": state.processedCount,
                    "snapshotEpochID": state.snapshotEpochID
                }
            }
            return nil
        }
        
        access(all) view fun getUserProjectedStake(receiverID: UInt64, atTime: UFix64): UFix64 {
            return self.savingsDistributor.calculateStakeAtTime(receiverID: receiverID, targetTime: atTime)
        }
        
        /// Preview how many shares would be minted for a deposit amount (ERC-4626 style)
        access(all) view fun previewDeposit(amount: UFix64): UFix64 {
            return self.savingsDistributor.convertToShares(amount)
        }
        
        /// Preview how many assets a number of shares is worth (ERC-4626 style)
        access(all) view fun previewRedeem(shares: UFix64): UFix64 {
            return self.savingsDistributor.convertToAssets(shares)
        }
        
        access(all) view fun getUserSavingsValue(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
        }
        
        access(all) view fun isReceiverRegistered(receiverID: UInt64): Bool {
            return self.registeredReceivers[receiverID] == true
        }
        
        access(all) view fun getRegisteredReceiverIDs(): [UInt64] {
            return self.registeredReceivers.keys
        }
        
        access(all) view fun isDrawInProgress(): Bool {
            return self.pendingDrawReceipt != nil
        }
        
        access(all) view fun getConfig(): PoolConfig {
            return self.config
        }
        
        access(all) view fun getTotalSavingsDistributed(): UFix64 {
            return self.savingsDistributor.getTotalDistributed()
        }
        
        access(all) view fun getCurrentReinvestedSavings(): UFix64 {
            if self.totalStaked > self.totalDeposited {
                return self.totalStaked - self.totalDeposited
            }
            return 0.0
        }
        
        access(all) fun getAvailableYieldRewards(): UFix64 {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let available = yieldSource.minimumAvailable()
            // Exclude already-allocated funds (same logic as processRewards)
            let allocatedFunds = self.totalStaked + self.pendingLotteryYield
            if available > allocatedFunds {
                return available - allocatedFunds
            }
            return 0.0
        }
        
        access(all) view fun getLotteryPoolBalance(): UFix64 {
            return self.lotteryDistributor.getPrizePoolBalance() + self.pendingLotteryYield
        }
        
        access(all) view fun getPendingLotteryYield(): UFix64 {
            return self.pendingLotteryYield
        }
        
        access(all) view fun getTreasuryRecipient(): Address? {
            return self.treasuryRecipientCap?.address
        }
        
        access(all) view fun hasTreasuryRecipient(): Bool {
            return self.treasuryRecipientCap != nil && self.treasuryRecipientCap!.check()
        }
        
        access(all) view fun getTotalTreasuryForwarded(): UFix64 {
            return self.totalTreasuryForwarded
        }
        
        /// Set treasury recipient for auto-forwarding. Only callable by account owner.
        access(contract) fun setTreasuryRecipient(cap: Capability<&{FungibleToken.Receiver}>?) {
            self.treasuryRecipientCap = cap
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
        access(all) view fun getRegisteredPoolIDs(): [UInt64]
        access(all) view fun isRegisteredWithPool(poolID: UInt64): Bool
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault})
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault}
        access(all) fun claimPendingNFT(poolID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT}
        access(all) view fun getPendingSavingsInterest(poolID: UInt64): UFix64
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance
        access(all) view fun getPendingNFTCount(poolID: UInt64): Int
        access(all) fun getPendingNFTIDs(poolID: UInt64): [UInt64]
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
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Pool does not exist")
            
            poolRef.registerReceiver(receiverID: self.uuid)
            self.registeredPools[poolID] = true
        }
        
        access(all) view fun getRegisteredPoolIDs(): [UInt64] {
            return self.registeredPools.keys
        }
        
        access(all) view fun isRegisteredWithPool(poolID: UInt64): Bool {
            return self.registeredPools[poolID] == true
        }
        
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault}) {
            if self.registeredPools[poolID] == nil {
                self.registerWithPool(poolID: poolID)
            }
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.deposit(from: <- from, receiverID: self.uuid)
        }
        
        access(all) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid)
        }
        
        access(all) fun claimPendingNFT(poolID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeSavings.borrowPoolInternal(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.claimPendingNFT(receiverID: self.uuid, nftIndex: nftIndex)
        }
        
        access(all) view fun getPendingNFTCount(poolID: UInt64): Int {
            let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            if poolRef == nil {
                return 0
            }
            return poolRef!.getPendingNFTCount(receiverID: self.uuid)
        }
        
        access(all) fun getPendingNFTIDs(poolID: UInt64): [UInt64] {
            let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            if poolRef == nil {
                return []
            }
            return poolRef!.getPendingNFTIDs(receiverID: self.uuid)
        }
        
        access(all) view fun getPendingSavingsInterest(poolID: UInt64): UFix64 {
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
        let pool <- create Pool(
            config: config, 
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
    
    /// Public view-only reference to a pool (no mutation allowed)
    access(all) view fun borrowPool(poolID: UInt64): &Pool? {
        return &self.pools[poolID]
    }
    
    /// Internal borrow with full authorization for Admin operations
    access(contract) fun borrowPoolInternal(poolID: UInt64): auth(CriticalOps, ConfigOps) &Pool? {
        return &self.pools[poolID]
    }
    
    access(all) view fun getAllPoolIDs(): [UInt64] {
        return self.pools.keys
    }
    
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    init() {
        // Virtual offset constants for ERC4626 inflation attack protection
        self.VIRTUAL_SHARES = 1.0
        self.VIRTUAL_ASSETS = 1.0
        
        self.PoolPositionCollectionStoragePath = /storage/PrizeSavingsCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeSavingsCollection
        
        self.AdminStoragePath = /storage/PrizeSavingsAdmin
        
        self.pools <- {}
        self.nextPoolID = 0
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}