/*
PrizeSavings - Prize-Linked Savings Protocol

No-loss lottery where users deposit tokens to earn guaranteed savings interest and lottery prizes.
Rewards auto-compound into deposits via ERC4626-style shares model.

Architecture:
- ERC4626-style shares with virtual offset protection (inflation attack resistant)
- TWAB (time-weighted average shares) using share-seconds for fair lottery weighting
- On-chain randomness via Flow's RandomConsumer
- Modular yield sources via DeFi Actions interface
- Configurable distribution strategies (savings/lottery/treasury split)
- Pluggable winner selection (weighted single, multi-winner, fixed tiers)
- Resource-based position ownership via PoolPositionCollection
- Emergency mode with auto-recovery and health monitoring
- NFT prize support with pending claims
- Direct funding for external sponsors
- Bonus lottery weights for promotions
- Winner tracking integration for leaderboards

Lottery Fairness:
- Uses share-seconds (shares × time) for lottery weighting
- Share-based TWAB is stable against price fluctuations (yield/loss)
- Rewards commitment: longer deposits = more accumulated share-seconds
- Early depositors get more shares per dollar, increasing lottery weight

Core Components:
- SavingsDistributor: Shares vault with share-seconds tracking for lottery weights
- LotteryDistributor: Prize pool, NFT prizes, and draw execution
- Pool: Deposits, withdrawals, yield processing, and prize draws
- PoolPositionCollection: User's resource for interacting with pools
- Admin: Pool configuration and emergency operations
*/

import "FungibleToken"
import "NonFungibleToken"
import "RandomConsumer"
import "DeFiActions"
import "DeFiActionsUtils"
import "PrizeWinnerTracker"
import "Xorshift128plus"

access(all) contract PrizeSavings {    
    /// Entitlement for configuration operations (non-destructive admin actions).
    /// Examples: updating draw intervals, processing rewards, managing bonus weights.
    access(all) entitlement ConfigOps
    
    /// Entitlement for critical operations (potentially destructive admin actions).
    /// Examples: creating pools, enabling emergency mode, starting/completing draws.
    access(all) entitlement CriticalOps
    
    /// Entitlement reserved exclusively for account owner operations.
    /// SECURITY: Never issue capabilities with this entitlement - it protects
    /// treasury recipient configuration which could redirect funds if compromised.
    access(all) entitlement OwnerOnly
    
    /// Entitlement for user position operations (deposit, withdraw, claim).
    /// Users must have this entitlement to interact with their pool positions.
    access(all) entitlement PositionOps
    
    // ============================================================
    // CONSTANTS
    // ============================================================
    
    /// Virtual offset constant for ERC4626 inflation attack protection (shares).
    /// Creates "dead" shares that prevent share price manipulation by early depositors.
    /// Using 0.0001 to minimize user dilution (~0.0001%) while maintaining security.
    /// See: https://blog.openzeppelin.com/a-]novel-defense-against-erc4626-inflation-attacks
    access(all) let VIRTUAL_SHARES: UFix64
    
    /// Virtual offset constant for ERC4626 inflation attack protection (assets).
    /// Works in tandem with VIRTUAL_SHARES to ensure share price starts near 1.0.
    access(all) let VIRTUAL_ASSETS: UFix64
    
    // ============================================================
    // STORAGE PATHS
    // ============================================================
    
    /// Storage path where users store their PoolPositionCollection resource.
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    
    /// Public path for PoolPositionCollection capability (read-only access).
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    // ============================================================
    // EVENTS - Core Operations
    // ============================================================
    
    /// Emitted when a new prize pool is created.
    /// @param poolID - Unique identifier for the pool
    /// @param assetType - Type identifier of the fungible token (e.g., "A.xxx.FlowToken.Vault")
    /// @param strategy - Name of the distribution strategy in use
    access(all) event PoolCreated(poolID: UInt64, assetType: String, strategy: String)
    
    /// Emitted when a user deposits funds into a pool.
    /// @param poolID - Pool receiving the deposit
    /// @param receiverID - UUID of the user's PoolPositionCollection
    /// @param amount - Amount deposited
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    
    /// Emitted when a user withdraws funds from a pool.
    /// @param poolID - Pool being withdrawn from
    /// @param receiverID - UUID of the user's PoolPositionCollection
    /// @param requestedAmount - Amount the user requested to withdraw
    /// @param actualAmount - Amount actually withdrawn (may be less if yield source has insufficient liquidity)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, requestedAmount: UFix64, actualAmount: UFix64)
    
    // ============================================================
    // EVENTS - Reward Processing
    // ============================================================
    
    /// Emitted when yield rewards are processed and distributed.
    /// @param poolID - Pool processing rewards
    /// @param totalAmount - Total yield amount processed
    /// @param savingsAmount - Portion allocated to savings (auto-compounds)
    /// @param lotteryAmount - Portion allocated to lottery prize pool
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, savingsAmount: UFix64, lotteryAmount: UFix64)
    
    /// Emitted when savings yield is accrued to the share price.
    /// @param poolID - Pool accruing yield
    /// @param amount - Amount of yield accrued (increases share price for all depositors)
    access(all) event SavingsYieldAccrued(poolID: UInt64, amount: UFix64)
    
    /// Emitted when a deficit is applied across allocations.
    /// @param poolID - Pool experiencing the deficit
    /// @param totalDeficit - Total deficit amount detected
    /// @param absorbedByLottery - Amount absorbed by pending lottery yield
    /// @param absorbedBySavings - Amount absorbed by savings (decreases share price)
    access(all) event DeficitApplied(poolID: UInt64, totalDeficit: UFix64, absorbedByLottery: UFix64, absorbedBySavings: UFix64)
    
    /// Emitted when rounding dust from savings distribution is sent to treasury.
    /// This occurs due to virtual shares absorbing a tiny fraction of yield.
    /// @param poolID - Pool generating dust
    /// @param amount - Dust amount routed to treasury
    access(all) event SavingsRoundingDustToTreasury(poolID: UInt64, amount: UFix64)
    
    // ============================================================
    // EVENTS - Lottery/Draw
    // ============================================================
    
    /// Emitted when a prize draw is committed (randomness requested).
    /// @param poolID - Pool starting the draw
    /// @param prizeAmount - Total prize pool amount for this draw
    /// @param commitBlock - Block height at which randomness was requested
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64)
    
    /// Emitted when prizes are awarded to winners.
    /// @param poolID - Pool awarding prizes
    /// @param winners - Array of winner receiverIDs
    /// @param amounts - Array of prize amounts (parallel to winners)
    /// @param round - Draw round number
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], amounts: [UFix64], round: UInt64)
    
    /// Emitted when the lottery prize pool receives funding.
    /// @param poolID - Pool receiving funds
    /// @param amount - Amount added to prize pool
    /// @param source - Source of funding (e.g., "yield_pending", "direct")
    access(all) event LotteryPrizePoolFunded(poolID: UInt64, amount: UFix64, source: String)
    
    /// Emitted when a new lottery epoch begins (after a draw completes).
    /// @param poolID - Pool starting new round
    /// @param roundID - New round identifier
    /// @param startTime - Timestamp when round started
    /// @param duration - Round duration in seconds
    access(all) event NewRoundStarted(poolID: UInt64, roundID: UInt64, startTime: UFix64, duration: UFix64)
    
    /// Emitted when batch draw processing begins.
    /// @param poolID - ID of the pool
    /// @param endedRoundID - Round that ended and is being processed
    /// @param newRoundID - New round that started
    /// @param totalReceivers - Number of receivers to process in batches
    access(all) event DrawBatchStarted(poolID: UInt64, endedRoundID: UInt64, newRoundID: UInt64, totalReceivers: Int)
    
    /// Emitted when a batch of receivers is processed.
    /// @param poolID - ID of the pool
    /// @param processed - Number processed in this batch
    /// @param remaining - Number still to process
    access(all) event DrawBatchProcessed(poolID: UInt64, processed: Int, remaining: Int)
    
    /// Emitted when batch processing completes and randomness is requested.
    /// @param poolID - ID of the pool
    /// @param totalWeight - Total lottery weight captured
    /// @param prizeAmount - Prize pool amount
    /// @param commitBlock - Block where randomness was committed
    access(all) event DrawRandomnessRequested(poolID: UInt64, totalWeight: UFix64, prizeAmount: UFix64, commitBlock: UInt64)
    
    // ============================================================
    // EVENTS - Admin Configuration Changes
    // ============================================================
    
    /// Emitted when the distribution strategy is updated.
    /// @param poolID - ID of the pool being configured
    /// @param oldStrategy - Name of the previous distribution strategy
    /// @param newStrategy - Name of the new distribution strategy
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event DistributionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, adminUUID: UInt64)
    
    /// Emitted when the winner selection strategy is updated.
    /// @param poolID - ID of the pool being configured
    /// @param oldDistribution - Name of the previous prize distribution
    /// @param newDistribution - Name of the new prize distribution
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event PrizeDistributionUpdated(poolID: UInt64, oldDistribution: String, newDistribution: String, adminUUID: UInt64)
    
    /// Emitted when the winner tracker capability is updated.
    /// @param poolID - ID of the pool being configured
    /// @param hasOldTracker - Whether a tracker was previously configured
    /// @param hasNewTracker - Whether a tracker is now configured
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event WinnerTrackerUpdated(poolID: UInt64, hasOldTracker: Bool, hasNewTracker: Bool, adminUUID: UInt64)
    
    /// Emitted when the draw interval is changed.
    /// @param poolID - ID of the pool being configured
    /// @param oldInterval - Previous draw interval in seconds
    /// @param newInterval - New draw interval in seconds
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event DrawIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, adminUUID: UInt64)
    
    /// Emitted when the minimum deposit requirement is changed.
    /// @param poolID - ID of the pool being configured
    /// @param oldMinimum - Previous minimum deposit amount
    /// @param newMinimum - New minimum deposit amount
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event MinimumDepositUpdated(poolID: UInt64, oldMinimum: UFix64, newMinimum: UFix64, adminUUID: UInt64)
    
    /// Emitted when an admin creates a new pool.
    /// @param poolID - ID assigned to the newly created pool
    /// @param assetType - Type identifier of the fungible token the pool accepts
    /// @param strategy - Name of the initial distribution strategy
    /// @param adminUUID - UUID of the Admin resource that created the pool (audit trail)
    access(all) event PoolCreatedByAdmin(poolID: UInt64, assetType: String, strategy: String, adminUUID: UInt64)
    
    // ============================================================
    // EVENTS - Pool State Changes
    // ============================================================
    
    /// Emitted when a pool is paused (all operations disabled).
    /// @param poolID - Pool being paused
    /// @param adminUUID - UUID of the Admin resource performing the pause (audit trail)
    /// @param reason - Human-readable explanation for the pause
    access(all) event PoolPaused(poolID: UInt64, adminUUID: UInt64, reason: String)
    
    /// Emitted when a pool is unpaused (returns to normal operation).
    /// @param poolID - Pool being unpaused
    /// @param adminUUID - UUID of the Admin resource performing the unpause (audit trail)
    access(all) event PoolUnpaused(poolID: UInt64, adminUUID: UInt64)
    
    /// Emitted when the treasury receives funding (legacy event).
    /// @param poolID - Pool whose treasury received funds
    /// @param amount - Amount of tokens funded
    /// @param source - Source of funding (e.g., "rounding_dust", "fees")
    access(all) event TreasuryFunded(poolID: UInt64, amount: UFix64, source: String)
    
    /// Emitted when the treasury recipient address is changed.
    /// SECURITY: This is a sensitive operation - recipient receives protocol fees.
    /// @param poolID - Pool being configured
    /// @param newRecipient - New treasury recipient address (nil to disable forwarding)
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event TreasuryRecipientUpdated(poolID: UInt64, newRecipient: Address?, adminUUID: UInt64)
    
    /// Emitted when treasury funds are auto-forwarded to the configured recipient.
    /// @param poolID - Pool forwarding treasury funds
    /// @param amount - Amount forwarded
    /// @param recipient - Address receiving the funds
    access(all) event TreasuryForwarded(poolID: UInt64, amount: UFix64, recipient: Address)
    
    // ============================================================
    // EVENTS - Bonus Weight Management
    // ============================================================
    
    /// Emitted when a user's bonus lottery weight is set (replaces existing).
    /// Bonus weights increase lottery odds for promotional purposes.
    /// @param poolID - Pool where bonus is being set
    /// @param receiverID - UUID of the user's PoolPositionCollection receiving the bonus
    /// @param bonusWeight - New bonus weight value (replaces any existing bonus)
    /// @param reason - Human-readable explanation for the bonus (e.g., "referral", "promotion")
    /// @param adminUUID - UUID of the Admin resource setting the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was set
    access(all) event BonusLotteryWeightSet(poolID: UInt64, receiverID: UInt64, bonusWeight: UFix64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when additional bonus weight is added to a user's existing bonus.
    /// @param poolID - Pool where bonus is being added
    /// @param receiverID - UUID of the user's PoolPositionCollection receiving additional bonus
    /// @param additionalWeight - Amount of weight being added
    /// @param newTotalBonus - User's new total bonus weight after addition
    /// @param reason - Human-readable explanation for the bonus addition
    /// @param adminUUID - UUID of the Admin resource adding the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was added
    access(all) event BonusLotteryWeightAdded(poolID: UInt64, receiverID: UInt64, additionalWeight: UFix64, newTotalBonus: UFix64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when a user's bonus lottery weight is completely removed.
    /// @param poolID - Pool where bonus is being removed
    /// @param receiverID - UUID of the user's PoolPositionCollection losing the bonus
    /// @param previousBonus - Bonus weight that was removed
    /// @param adminUUID - UUID of the Admin resource removing the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was removed
    access(all) event BonusLotteryWeightRemoved(poolID: UInt64, receiverID: UInt64, previousBonus: UFix64, adminUUID: UInt64, timestamp: UFix64)
    
    // ============================================================
    // EVENTS - NFT Prize Management
    // ============================================================
    
    /// Emitted when an NFT is deposited as a potential prize.
    /// @param poolID - Pool receiving the NFT prize
    /// @param nftID - UUID of the deposited NFT
    /// @param nftType - Type identifier of the NFT (e.g., "A.xxx.ExampleNFT.NFT")
    /// @param adminUUID - UUID of the Admin resource depositing the NFT (audit trail)
    access(all) event NFTPrizeDeposited(poolID: UInt64, nftID: UInt64, nftType: String, adminUUID: UInt64)
    
    /// Emitted when an NFT prize is awarded to a winner.
    /// @param poolID - Pool awarding the NFT
    /// @param receiverID - UUID of the winner's PoolPositionCollection
    /// @param nftID - UUID of the awarded NFT
    /// @param nftType - Type identifier of the NFT
    /// @param round - Draw round number when the NFT was awarded
    access(all) event NFTPrizeAwarded(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String, round: UInt64)
    
    /// Emitted when an NFT is stored in pending claims for a winner.
    /// NFTs are stored rather than directly transferred since we don't have winner's collection reference.
    /// @param poolID - Pool storing the pending NFT
    /// @param receiverID - UUID of the winner's PoolPositionCollection
    /// @param nftID - UUID of the stored NFT
    /// @param nftType - Type identifier of the NFT
    /// @param reason - Explanation for why NFT is pending (e.g., "lottery_win")
    access(all) event NFTPrizeStored(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String, reason: String)
    
    /// Emitted when a winner claims their pending NFT prize.
    /// @param poolID - Pool from which NFT is claimed
    /// @param receiverID - UUID of the claimant's PoolPositionCollection
    /// @param nftID - UUID of the claimed NFT
    /// @param nftType - Type identifier of the NFT
    access(all) event NFTPrizeClaimed(poolID: UInt64, receiverID: UInt64, nftID: UInt64, nftType: String)
    
    /// Emitted when an admin withdraws an NFT prize (before it's awarded).
    /// @param poolID - Pool from which NFT is withdrawn
    /// @param nftID - UUID of the withdrawn NFT
    /// @param nftType - Type identifier of the NFT
    /// @param adminUUID - UUID of the Admin resource withdrawing the NFT (audit trail)
    access(all) event NFTPrizeWithdrawn(poolID: UInt64, nftID: UInt64, nftType: String, adminUUID: UInt64)
    
    // ============================================================
    // EVENTS - Emergency Mode
    // ============================================================
    
    /// Emitted when emergency mode is enabled by an admin.
    /// Emergency mode: only withdrawals allowed, no deposits or draws.
    /// @param poolID - Pool entering emergency mode
    /// @param reason - Human-readable explanation for enabling emergency mode
    /// @param adminUUID - UUID of the Admin resource enabling emergency mode (audit trail)
    /// @param timestamp - Block timestamp when emergency mode was enabled
    access(all) event PoolEmergencyEnabled(poolID: UInt64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when emergency mode is disabled by an admin.
    /// @param poolID - Pool exiting emergency mode
    /// @param adminUUID - UUID of the Admin resource disabling emergency mode (audit trail)
    /// @param timestamp - Block timestamp when emergency mode was disabled
    access(all) event PoolEmergencyDisabled(poolID: UInt64, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when partial mode is enabled (limited deposits, no draws).
    /// @param poolID - Pool entering partial mode
    /// @param reason - Human-readable explanation for enabling partial mode
    /// @param adminUUID - UUID of the Admin resource enabling partial mode (audit trail)
    /// @param timestamp - Block timestamp when partial mode was enabled
    access(all) event PoolPartialModeEnabled(poolID: UInt64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when emergency mode is auto-triggered due to health checks.
    /// Auto-triggers: low yield source health, consecutive withdrawal failures.
    /// @param poolID - Pool auto-entering emergency mode
    /// @param reason - Explanation for auto-trigger (e.g., "low_health_score", "withdrawal_failures")
    /// @param healthScore - Current health score that triggered emergency mode (0.0-1.0)
    /// @param timestamp - Block timestamp when auto-triggered
    access(all) event EmergencyModeAutoTriggered(poolID: UInt64, reason: String, healthScore: UFix64, timestamp: UFix64)
    
    /// Emitted when the pool auto-recovers from emergency mode.
    /// Recovery occurs when yield source health returns to normal.
    /// @param poolID - Pool auto-recovering from emergency mode
    /// @param reason - Explanation for recovery (e.g., "health_restored")
    /// @param healthScore - Current health score (nil if not applicable)
    /// @param duration - How long the pool was in emergency mode in seconds (nil if not tracked)
    /// @param timestamp - Block timestamp when auto-recovered
    access(all) event EmergencyModeAutoRecovered(poolID: UInt64, reason: String, healthScore: UFix64?, duration: UFix64?, timestamp: UFix64)
    
    /// Emitted when emergency configuration is updated.
    /// @param poolID - Pool whose emergency config was updated
    /// @param adminUUID - UUID of the Admin resource updating the config (audit trail)
    access(all) event EmergencyConfigUpdated(poolID: UInt64, adminUUID: UInt64)
    
    /// Emitted when a withdrawal fails (usually due to yield source liquidity issues).
    /// Multiple consecutive failures may trigger emergency mode.
    /// @param poolID - Pool where withdrawal failed
    /// @param receiverID - UUID of the user's PoolPositionCollection attempting withdrawal
    /// @param amount - Amount the user attempted to withdraw
    /// @param consecutiveFailures - Running count of consecutive withdrawal failures
    /// @param yieldAvailable - Amount currently available in yield source
    access(all) event WithdrawalFailure(poolID: UInt64, receiverID: UInt64, amount: UFix64, consecutiveFailures: Int, yieldAvailable: UFix64)
    
    // ============================================================
    // EVENTS - Direct Funding
    // ============================================================
    
    /// Emitted when an admin directly funds a pool component.
    /// Used for external sponsorships or manual prize pool funding.
    /// @param poolID - Pool receiving the direct funding
    /// @param destination - Numeric destination code: 0=Savings, 1=Lottery (see PoolFundingDestination enum)
    /// @param destinationName - Human-readable destination name (e.g., "Savings", "Lottery")
    /// @param amount - Amount of tokens being funded
    /// @param adminUUID - UUID of the Admin resource performing the funding (audit trail)
    /// @param purpose - Human-readable explanation for the funding (e.g., "weekly_sponsorship")
    /// @param metadata - Additional key-value metadata for the funding event
    access(all) event DirectFundingReceived(poolID: UInt64, destination: UInt8, destinationName: String, amount: UFix64, adminUUID: UInt64, purpose: String, metadata: {String: String})
    
    // ============================================================
    // CONTRACT STATE
    // ============================================================
    
    /// Mapping of pool IDs to Pool resources.
    /// TODO: Consider storage limits - large pools could exceed account storage.
    access(self) var pools: @{UInt64: Pool}
    
    /// Auto-incrementing counter for generating unique pool IDs.
    access(self) var nextPoolID: UInt64
    
    // ============================================================
    // ENUMS
    // ============================================================
    
    /// Represents the operational state of a pool.
    /// Determines which operations are allowed.
    access(all) enum PoolEmergencyState: UInt8 {
        /// Normal operation - all functions available
        access(all) case Normal
        /// Completely paused - no operations allowed
        access(all) case Paused
        /// Emergency mode - only withdrawals allowed, no deposits or draws
        access(all) case EmergencyMode
        /// Partial mode - limited deposits (up to configured limit), no draws
        access(all) case PartialMode
    }
    
    /// Specifies the destination for direct funding operations.
    /// Used by admin's fundPoolDirect() function.
    access(all) enum PoolFundingDestination: UInt8 {
        /// Fund the savings distributor (increases share price for all users)
        access(all) case Savings
        /// Fund the lottery prize pool (available for next draw)
        access(all) case Lottery
    }
    
    // ============================================================
    // STRUCTS
    // ============================================================
    
    /// Records metadata about a bonus lottery weight assigned to a user.
    /// Bonus weights increase a user's lottery odds for promotional purposes.
    /// The weight is added to their TWAB-based weight during draw selection.
    access(all) struct BonusWeightRecord {
        /// The bonus weight value (added to TWAB weight during draws)
        access(all) let bonusWeight: UFix64
        /// Human-readable reason for the bonus (e.g., "Early adopter promotion")
        access(all) let reason: String
        /// Timestamp when this bonus was added
        access(all) let addedAt: UFix64
        /// UUID of the Admin resource that added this bonus (audit trail)
        access(all) let adminUUID: UInt64
        
        /// Creates a new BonusWeightRecord.
        /// @param bonusWeight - Must be positive (> 0.0)
        /// @param reason - Must be non-empty (for audit purposes)
        /// @param adminUUID - UUID of admin performing the action
        init(bonusWeight: UFix64, reason: String, adminUUID: UInt64) {
            pre {
                bonusWeight > 0.0: "Bonus weight must be greater than zero"
                reason.length > 0: "Reason cannot be empty"
            }
            self.bonusWeight = bonusWeight
            self.reason = reason
            self.addedAt = getCurrentBlock().timestamp
            self.adminUUID = adminUUID
        }
    }
    
    /// Configuration parameters for emergency mode behavior.
    /// Controls auto-triggering, auto-recovery, and partial mode limits.
    access(all) struct EmergencyConfig {
        /// Maximum time (seconds) to stay in emergency mode before auto-recovery.
        /// nil = no time limit, manual intervention required.
        access(all) let maxEmergencyDuration: UFix64?
        
        /// Whether the pool should attempt to auto-recover from emergency mode
        /// when health metrics improve.
        access(all) let autoRecoveryEnabled: Bool
        
        /// Minimum yield source health score (0.0-1.0) below which emergency triggers.
        /// Health is calculated from balance ratio and withdrawal success rate.
        access(all) let minYieldSourceHealth: UFix64
        
        /// Number of consecutive withdrawal failures that triggers emergency mode.
        access(all) let maxWithdrawFailures: Int
        
        /// Maximum deposit amount allowed during partial mode.
        /// nil = deposits disabled in partial mode.
        access(all) let partialModeDepositLimit: UFix64?
        
        /// Minimum ratio of yield source balance to totalStaked (0.8-1.0).
        /// Below this ratio, health score is reduced.
        access(all) let minBalanceThreshold: UFix64
        
        /// Minimum health score required for time-based auto-recovery.
        /// Prevents recovery when yield source is still critically unhealthy.
        access(all) let minRecoveryHealth: UFix64
        
        /// Creates an EmergencyConfig with validated parameters.
        /// @param maxEmergencyDuration - Max seconds in emergency (nil = unlimited)
        /// @param autoRecoveryEnabled - Enable auto-recovery on health improvement
        /// @param minYieldSourceHealth - Health threshold for emergency trigger (0.0-1.0)
        /// @param maxWithdrawFailures - Failure count before emergency (must be >= 1)
        /// @param partialModeDepositLimit - Deposit limit in partial mode (nil = disabled)
        /// @param minBalanceThreshold - Balance ratio for health calc (0.8-1.0)
        /// @param minRecoveryHealth - Min health for time-based recovery (0.0-1.0)
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
                minYieldSourceHealth >= 0.0 && minYieldSourceHealth <= 1.0: "minYieldSourceHealth must be between 0.0 and 1.0 but got ".concat(minYieldSourceHealth.toString())
                maxWithdrawFailures > 0: "maxWithdrawFailures must be at least 1 but got ".concat(maxWithdrawFailures.toString())
                minBalanceThreshold >= 0.8 && minBalanceThreshold <= 1.0: "minBalanceThreshold must be between 0.8 and 1.0 but got ".concat(minBalanceThreshold.toString())
                (minRecoveryHealth ?? 0.5) >= 0.0 && (minRecoveryHealth ?? 0.5) <= 1.0: "minRecoveryHealth must be between 0.0 and 1.0 but got ".concat((minRecoveryHealth ?? 0.5).toString())
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
    
    /// Creates a default EmergencyConfig with sensible production defaults.
    /// - 24 hour max emergency duration
    /// - Auto-recovery enabled
    /// - 50% min yield source health
    /// - 3 consecutive failures triggers emergency
    /// - 100 token partial mode deposit limit
    /// - 95% min balance threshold
    /// @return A pre-configured EmergencyConfig
    access(all) fun createDefaultEmergencyConfig(): EmergencyConfig {
        return EmergencyConfig(
            maxEmergencyDuration: 86400.0,          // 24 hours
            autoRecoveryEnabled: true,
            minYieldSourceHealth: 0.5,              // 50%
            maxWithdrawFailures: 3,
            partialModeDepositLimit: 100.0,
            minBalanceThreshold: 0.95,              // 95%
            minRecoveryHealth: 0.5                  // 50%
        )
    }
    
    // ============================================================
    // ADMIN RESOURCE
    // ============================================================
    
    /// Admin resource providing privileged access to pool management operations.
    /// 
    /// The Admin resource uses entitlements to provide fine-grained access control:
    /// - ConfigOps: Non-destructive configuration changes (draw intervals, bonuses, rewards)
    /// - CriticalOps: Potentially impactful changes (strategies, emergency mode, draws)
    /// - OwnerOnly: Highly sensitive operations (treasury recipient - NEVER issue capabilities)
    /// 
    /// SECURITY NOTES:
    /// - Store in a secure account
    /// - Issue capabilities with minimal required entitlements
    /// - Admin UUID is logged in events for audit trail
    access(all) resource Admin {
        /// Extensible metadata storage for future use.
        access(self) var metadata: {String: {String: AnyStruct}}
        
        init() {
            self.metadata = {}
        }

        /// Updates the yield distribution strategy for a pool.
        /// @param poolID - ID of the pool to update
        /// @param newStrategy - The new distribution strategy to use
        access(CriticalOps) fun updatePoolDistributionStrategy(
            poolID: UInt64,
            newStrategy: {DistributionStrategy}
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let oldStrategyName = poolRef.getDistributionStrategyName()
            poolRef.setDistributionStrategy(strategy: newStrategy)
            let newStrategyName = newStrategy.getStrategyName()
            
            emit DistributionStrategyUpdated(
                poolID: poolID,
                oldStrategy: oldStrategyName,
                newStrategy: newStrategyName,
                adminUUID: self.uuid
            )
        }
        
        /// Updates the prize distribution for lottery draws.
        /// @param poolID - ID of the pool to update
        /// @param newDistribution - The new prize distribution (e.g., single winner, percentage split)
        access(CriticalOps) fun updatePoolPrizeDistribution(
            poolID: UInt64,
            newDistribution: {PrizeDistribution}
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let oldDistributionName = poolRef.getPrizeDistributionName()
            poolRef.setPrizeDistribution(distribution: newDistribution)
            let newDistributionName = newDistribution.getDistributionName()
            
            emit PrizeDistributionUpdated(
                poolID: poolID,
                oldDistribution: oldDistributionName,
                newDistribution: newDistributionName,
                adminUUID: self.uuid
            )
        }
        
        /// Updates or removes the winner tracker capability.
        /// Winner tracker is used for external leaderboard/statistics integrations.
        /// @param poolID - ID of the pool to update
        /// @param newTrackerCap - Capability to winner tracker, or nil to disable
        access(ConfigOps) fun updatePoolWinnerTracker(
            poolID: UInt64,
            newTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let hasOldTracker = poolRef.hasWinnerTracker()
            poolRef.setWinnerTrackerCap(cap: newTrackerCap)
            let hasNewTracker = newTrackerCap != nil
            
            emit WinnerTrackerUpdated(
                poolID: poolID,
                hasOldTracker: hasOldTracker,
                hasNewTracker: hasNewTracker,
                adminUUID: self.uuid
            )
        }
        
        /// Updates the minimum time between lottery draws.
        /// @param poolID - ID of the pool to update
        /// @param newInterval - New draw interval in seconds (must be >= 1.0)
        access(ConfigOps) fun updatePoolDrawInterval(
            poolID: UInt64,
            newInterval: UFix64
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let oldInterval = poolRef.getConfig().drawIntervalSeconds
            poolRef.setDrawIntervalSeconds(interval: newInterval)
            
            emit DrawIntervalUpdated(
                poolID: poolID,
                oldInterval: oldInterval,
                newInterval: newInterval,
                adminUUID: self.uuid
            )
        }
        
        /// Updates the minimum deposit amount for the pool.
        /// @param poolID - ID of the pool to update
        /// @param newMinimum - New minimum deposit (>= 0.0)
        access(ConfigOps) fun updatePoolMinimumDeposit(
            poolID: UInt64,
            newMinimum: UFix64
        ) { 
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let oldMinimum = poolRef.getConfig().minimumDeposit
            poolRef.setMinimumDeposit(minimum: newMinimum)
            
            emit MinimumDepositUpdated(
                poolID: poolID,
                oldMinimum: oldMinimum,
                newMinimum: newMinimum,
                adminUUID: self.uuid
            )
        }
        
        /// Enables emergency mode for a pool.
        /// In emergency mode, only withdrawals are allowed - no deposits or draws.
        /// Use when yield source is compromised or protocol issues detected.
        /// @param poolID - ID of the pool to put in emergency mode
        /// @param reason - Human-readable reason for emergency (logged in event)
        access(CriticalOps) fun enableEmergencyMode(poolID: UInt64, reason: String) {
            pre {
                reason.length > 0: "Reason cannot be empty. Pool ID: ".concat(poolID.toString())
            }
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.setEmergencyMode(reason: reason)
            emit PoolEmergencyEnabled(poolID: poolID, reason: reason, adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Disables emergency mode and returns pool to normal operation.
        /// Clears consecutive failure counter and enables all operations.
        /// @param poolID - ID of the pool to restore
        access(CriticalOps) fun disableEmergencyMode(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.clearEmergencyMode()
            emit PoolEmergencyDisabled(poolID: poolID, adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Enables partial mode for a pool.
        /// Partial mode: limited deposits (up to configured limit), no draws.
        /// Use for graceful degradation when full operation isn't safe.
        /// @param poolID - ID of the pool
        /// @param reason - Human-readable reason for partial mode
        access(CriticalOps) fun setEmergencyPartialMode(poolID: UInt64, reason: String) {
            pre {
                reason.length > 0: "Reason cannot be empty. Pool ID: ".concat(poolID.toString())
            }
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.setPartialMode(reason: reason)
            emit PoolPartialModeEnabled(poolID: poolID, reason: reason, adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Updates the emergency configuration for a pool.
        /// Controls auto-triggering thresholds and recovery behavior.
        /// @param poolID - ID of the pool to configure
        /// @param newConfig - New emergency configuration
        access(CriticalOps) fun updateEmergencyConfig(poolID: UInt64, newConfig: EmergencyConfig) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.setEmergencyConfig(config: newConfig)
            emit EmergencyConfigUpdated(poolID: poolID, adminUUID: self.uuid)
        }
        
        /// Directly funds a pool component with external tokens.
        /// Use for sponsorships, promotional prize pools, or yield subsidies.
        /// @param poolID - ID of the pool to fund
        /// @param destination - Where to route funds (Savings or Lottery)
        /// @param from - Vault containing funds to deposit
        /// @param purpose - Human-readable description of funding purpose
        /// @param metadata - Optional key-value pairs for additional context
        access(CriticalOps) fun fundPoolDirect(
            poolID: UInt64,
            destination: PoolFundingDestination,
            from: @{FungibleToken.Vault},
            purpose: String,
            metadata: {String: String}?
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            let amount = from.balance
            poolRef.fundDirectInternal(destination: destination, from: <- from, adminUUID: self.uuid, purpose: purpose, metadata: metadata ?? {})
            
            emit DirectFundingReceived(
                poolID: poolID,
                destination: destination.rawValue,
                destinationName: self.getDestinationName(destination),
                amount: amount,
                adminUUID: self.uuid,
                purpose: purpose,
                metadata: metadata ?? {}
            )
        }
        
        /// Internal helper to convert funding destination enum to human-readable string.
        access(self) fun getDestinationName(_ destination: PoolFundingDestination): String {
            switch destination {
                case PoolFundingDestination.Savings: return "Savings"
                case PoolFundingDestination.Lottery: return "Lottery"
                default: return "Unknown"
            }
        }
        
        /// Creates a new prize savings pool.
        /// @param config - Pool configuration (asset type, yield connector, strategies, etc.)
        /// @param emergencyConfig - Optional emergency configuration (uses defaults if nil)
        /// @return The ID of the newly created pool
        access(CriticalOps) fun createPool(
            config: PoolConfig,
            emergencyConfig: EmergencyConfig?
        ): UInt64 {
            // Use provided config or fall back to sensible defaults
            let finalEmergencyConfig = emergencyConfig 
                ?? PrizeSavings.createDefaultEmergencyConfig()
            
            let poolID = PrizeSavings.createPool(
                config: config,
                emergencyConfig: finalEmergencyConfig
            )
            
            emit PoolCreatedByAdmin(
                poolID: poolID,
                assetType: config.assetType.identifier,
                strategy: config.distributionStrategy.getStrategyName(),
                adminUUID: self.uuid
            )
            
            return poolID
        }
        
        /// Manually triggers reward processing for a pool.
        /// Normally called automatically during deposits, but can be called explicitly
        /// to materialize pending yield before a draw.
        /// @param poolID - ID of the pool to process rewards for
        access(ConfigOps) fun processPoolRewards(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.syncWithYieldSource()
        }
        
        /// Directly sets the pool's operational state.
        /// Provides unified interface for all state transitions.
        /// @param poolID - ID of the pool
        /// @param state - Target state (Normal, Paused, EmergencyMode, PartialMode)
        /// @param reason - Optional reason for non-Normal states
        access(CriticalOps) fun setPoolState(poolID: UInt64, state: PoolEmergencyState, reason: String?) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.setState(state: state, reason: reason)
            
            // Emit appropriate event based on new state
            switch state {
                case PoolEmergencyState.Normal:
                    emit PoolUnpaused(poolID: poolID, adminUUID: self.uuid)
                case PoolEmergencyState.Paused:
                    emit PoolPaused(poolID: poolID, adminUUID: self.uuid, reason: reason ?? "Manual pause")
                case PoolEmergencyState.EmergencyMode:
                    emit PoolEmergencyEnabled(poolID: poolID, reason: reason ?? "Emergency", adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
                case PoolEmergencyState.PartialMode:
                    emit PoolPartialModeEnabled(poolID: poolID, reason: reason ?? "Partial mode", adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
            }
        }
        
        /// Set the treasury recipient for automatic forwarding.
        /// Once set, treasury funds are auto-forwarded during syncWithYieldSource().
        /// Pass nil to disable auto-forwarding (funds stored in distributor).
        /// 
        /// SECURITY: Requires OwnerOnly entitlement - NEVER issue capabilities with this.
        /// Only the account owner (via direct storage borrow with auth) can call this.
        /// For multi-sig protection, store Admin in a multi-sig account.
        /// 
        /// @param poolID - ID of the pool to configure
        /// @param recipientCap - Capability to receive treasury funds, or nil to disable
        access(OwnerOnly) fun setPoolTreasuryRecipient(
            poolID: UInt64,
            recipientCap: Capability<&{FungibleToken.Receiver}>?
        ) {
            pre {
                // Validate capability is usable if provided
                recipientCap?.check() ?? true: "Treasury recipient capability is invalid or cannot be borrowed. Pool ID: ".concat(poolID.toString()).concat(", Recipient address: ").concat(recipientCap?.address?.toString() ?? "nil")
            }
            
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.setTreasuryRecipient(cap: recipientCap)
            
            emit TreasuryRecipientUpdated(
                poolID: poolID,
                newRecipient: recipientCap?.address,
                adminUUID: self.uuid
            )
        }
        
        /// Sets or replaces a user's bonus lottery weight.
        /// Bonus weight is added to their TWAB-based weight during draw selection.
        /// Use for promotional campaigns or loyalty rewards.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        /// @param bonusWeight - Weight to assign (replaces any existing bonus)
        /// @param reason - Human-readable reason for the bonus (audit trail)
        access(ConfigOps) fun setBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            bonusWeight: UFix64,
            reason: String
        ) {
            pre {
                reason.length > 0: "Reason cannot be empty. Pool ID: ".concat(poolID.toString()).concat(", Receiver ID: ").concat(receiverID.toString())
            }
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.setBonusWeight(receiverID: receiverID, bonusWeight: bonusWeight, reason: reason, adminUUID: self.uuid)
        }
        
        /// Adds additional bonus weight to a user's existing bonus.
        /// Cumulative with any previous bonus weight assigned.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        /// @param additionalWeight - Weight to add (must be > 0)
        /// @param reason - Human-readable reason for the addition
        access(ConfigOps) fun addBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64,
            additionalWeight: UFix64,
            reason: String
        ) {
            pre {
                additionalWeight > 0.0: "Additional weight must be positive (greater than 0). Pool ID: ".concat(poolID.toString()).concat(", Receiver ID: ").concat(receiverID.toString()).concat(", Received weight: ").concat(additionalWeight.toString())
                reason.length > 0: "Reason cannot be empty. Pool ID: ".concat(poolID.toString()).concat(", Receiver ID: ").concat(receiverID.toString())
            }
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.addBonusWeight(receiverID: receiverID, additionalWeight: additionalWeight, reason: reason, adminUUID: self.uuid)
        }
        
        /// Removes all bonus lottery weight from a user.
        /// User returns to pure TWAB-based lottery odds.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        access(ConfigOps) fun removeBonusLotteryWeight(
            poolID: UInt64,
            receiverID: UInt64
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            poolRef.removeBonusWeight(receiverID: receiverID, adminUUID: self.uuid)
        }
        
        /// Deposits an NFT to be awarded as a prize in future draws.
        /// NFTs are stored in the lottery distributor and assigned via winner selection strategy.
        /// @param poolID - ID of the pool to receive the NFT
        /// @param nft - The NFT resource to deposit
        access(ConfigOps) fun depositNFTPrize(
            poolID: UInt64,
            nft: @{NonFungibleToken.NFT}
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let nftID = nft.uuid
            let nftType = nft.getType().identifier
            
            poolRef.depositNFTPrize(nft: <- nft)
            
            emit NFTPrizeDeposited(
                poolID: poolID,
                nftID: nftID,
                nftType: nftType,
                adminUUID: self.uuid
            )
        }
        
        /// Withdraws an NFT prize that hasn't been awarded yet.
        /// Use to recover NFTs or update prize pool contents.
        /// @param poolID - ID of the pool
        /// @param nftID - UUID of the NFT to withdraw
        /// @return The withdrawn NFT resource
        access(ConfigOps) fun withdrawNFTPrize(
            poolID: UInt64,
            nftID: UInt64
        ): @{NonFungibleToken.NFT} {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let nft <- poolRef.withdrawNFTPrize(nftID: nftID)
            let nftType = nft.getType().identifier
            
            emit NFTPrizeWithdrawn(
                poolID: poolID,
                nftID: nftID,
                nftType: nftType,
                adminUUID: self.uuid
            )
            
            return <- nft
        }
        
        // ============================================================
        // BATCH DRAW FUNCTIONS
        // ============================================================
        // BATCHED DRAW OPERATIONS
        // ============================================================
        // Breaks draw into multiple transactions to avoid gas limits for large pools.
        // Flow: startPoolDraw() → processPoolDrawBatch() (repeat) → requestPoolDrawRandomness() → completePoolDraw()

        /// Starts a lottery draw for a pool (Phase 1 of 4).
        /// 
        /// This instantly transitions rounds and initializes batch processing.
        /// Users can continue depositing/withdrawing immediately.
        /// 
        /// @param poolID - ID of the pool to start draw for
        access(CriticalOps) fun startPoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.startDraw()
        }
        
        /// Processes a batch of receivers for weight capture (Phase 2 of 4).
        /// 
        /// Call repeatedly until return value is 0 (or isDrawBatchComplete()).
        /// Each call processes up to `limit` receivers.
        /// 
        /// @param poolID - ID of the pool
        /// @param limit - Maximum receivers to process this batch
        /// @return Number of receivers remaining to process
        access(CriticalOps) fun processPoolDrawBatch(poolID: UInt64, limit: Int): Int {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            return poolRef.processDrawBatch(limit: limit)
        }
        
        /// Requests randomness after batch processing complete (Phase 3 of 4).
        /// 
        /// Materializes pending yield, captures final weights, and commits to randomness.
        /// Must wait until next block before completeDraw().
        /// 
        /// @param poolID - ID of the pool
        access(CriticalOps) fun requestPoolDrawRandomness(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.requestDrawRandomness()
        }

        /// Completes a lottery draw for a pool (Phase 4 of 4).
        /// 
        /// Fulfills randomness request, selects winners, and distributes prizes.
        /// Prizes are auto-compounded into winners' deposits.
        /// 
        /// @param poolID - ID of the pool to complete draw for
        access(CriticalOps) fun completePoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.completeDraw()
        }

        /// Withdraws unclaimed treasury funds from a pool.
        /// 
        /// Treasury funds accumulate in the unclaimed vault when no treasury recipient
        /// is configured at draw time. This function allows admin to withdraw those funds.
        /// 
        /// @param poolID - ID of the pool to withdraw from
        /// @param amount - Amount to withdraw (will be capped at available balance)
        /// @param recipient - Capability to receive the withdrawn funds
        /// @return Actual amount withdrawn (may be less than requested if insufficient balance)
        access(CriticalOps) fun withdrawUnclaimedTreasury(
            poolID: UInt64,
            amount: UFix64,
            recipient: Capability<&{FungibleToken.Receiver}>
        ): UFix64 {
            pre {
                recipient.check(): "Recipient capability is invalid"
                amount > 0.0: "Amount must be greater than 0"
            }
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            let withdrawn <- poolRef.withdrawUnclaimedTreasury(amount: amount)
            let actualAmount = withdrawn.balance
            
            if actualAmount > 0.0 {
                recipient.borrow()!.deposit(from: <- withdrawn)
                emit TreasuryForwarded(
                    poolID: poolID,
                    amount: actualAmount,
                    recipient: recipient.address
                )
            } else {
                destroy withdrawn
            }
            
            return actualAmount
        }

    }
    
    /// Storage path for the Admin resource.
    access(all) let AdminStoragePath: StoragePath
    
    // ============================================================
    // DISTRIBUTION STRATEGY - Yield Allocation
    // ============================================================
    
    /// Represents the result of a yield distribution calculation.
    /// Contains the amounts to allocate to each component of the protocol.
    access(all) struct DistributionPlan {
        /// Amount allocated to savings (increases share price for all depositors)
        access(all) let savingsAmount: UFix64
        /// Amount allocated to lottery prize pool (awarded to winners)
        access(all) let lotteryAmount: UFix64
        /// Amount allocated to treasury (protocol fees)
        access(all) let treasuryAmount: UFix64
        
        /// Creates a new DistributionPlan.
        /// @param savings - Amount for savings distribution
        /// @param lottery - Amount for lottery prize pool
        /// @param treasury - Amount for protocol treasury
        init(savings: UFix64, lottery: UFix64, treasury: UFix64) {
            self.savingsAmount = savings
            self.lotteryAmount = lottery
            self.treasuryAmount = treasury
        }
    }
    
    /// Strategy Pattern interface for yield distribution algorithms.
    /// 
    /// Implementations determine how yield is split between savings, lottery, and treasury.
    /// This enables pools to use different distribution models and swap them at runtime.
    /// 
    /// IMPLEMENTATION NOTES:
    /// - Validation (e.g., percentages summing to 1.0) should be in concrete init()
    /// - calculateDistribution() must handle totalAmount = 0.0 gracefully
    /// - Strategy instances are stored by value (structs), so they're immutable after creation
    access(all) struct interface DistributionStrategy {
        /// Calculates how to split the given yield amount.
        /// @param totalAmount - Total yield to distribute
        /// @return DistributionPlan with amounts for each component
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan
        
        /// Returns a human-readable description of this strategy.
        /// Used for display in UI and event logging.
        access(all) view fun getStrategyName(): String
    }
    
    /// Fixed percentage distribution strategy.
    /// Splits yield according to pre-configured percentages that must sum to 1.0.
    /// 
    /// Example: FixedPercentageStrategy(savings: 0.4, lottery: 0.4, treasury: 0.2)
    /// - 40% of yield goes to savings (increases share price)
    /// - 40% goes to lottery prize pool
    /// - 20% goes to treasury
    access(all) struct FixedPercentageStrategy: DistributionStrategy {
        /// Percentage of yield allocated to savings (0.0 to 1.0)
        access(all) let savingsPercent: UFix64
        /// Percentage of yield allocated to lottery (0.0 to 1.0)
        access(all) let lotteryPercent: UFix64
        /// Percentage of yield allocated to treasury (0.0 to 1.0)
        access(all) let treasuryPercent: UFix64
        
        /// Creates a FixedPercentageStrategy.
        /// IMPORTANT: Percentages must sum to exactly 1.0 (strict equality).
        /// Use values like 0.4, 0.4, 0.2 - not repeating decimals like 0.33333333.
        /// If using thirds, use 0.33, 0.33, 0.34 to sum exactly to 1.0.
        /// @param savings - Savings percentage (0.0-1.0)
        /// @param lottery - Lottery percentage (0.0-1.0)
        /// @param treasury - Treasury percentage (0.0-1.0)
        init(savings: UFix64, lottery: UFix64, treasury: UFix64) {
            pre {
                savings + lottery + treasury == 1.0:
                    "FixedPercentageStrategy: Percentages must sum to exactly 1.0, but got "
                    .concat(savings.toString()).concat(" + ")
                    .concat(lottery.toString()).concat(" + ")
                    .concat(treasury.toString()).concat(" = ")
                    .concat((savings + lottery + treasury).toString())
            }
            self.savingsPercent = savings
            self.lotteryPercent = lottery
            self.treasuryPercent = treasury
        }
        
        /// Calculates distribution by multiplying total by each percentage.
        /// @param totalAmount - Total yield to distribute
        /// @return DistributionPlan with proportional amounts
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan {
            return DistributionPlan(
                savings: totalAmount * self.savingsPercent,
                lottery: totalAmount * self.lotteryPercent,
                treasury: totalAmount * self.treasuryPercent
            )
        }
        
        /// Returns strategy description with configured percentages.
        access(all) view fun getStrategyName(): String {
            return "Fixed: \(self.savingsPercent) savings, \(self.lotteryPercent) lottery, \(self.treasuryPercent) treasury"
        }
    }
    
    // ============================================================
    // ROUND RESOURCE - Per-Round TWAB Tracking
    // ============================================================
    
    /// Represents a single lottery round with projection-based TWAB tracking.
    /// 
    /// Each round is a separate resource that tracks:
    /// - Round timing (ID, start time, duration, end time)
    /// - User projected TWAB at round end
    /// 
    /// KEY CONCEPTS:
    /// 
    /// Projection-Based TWAB:
    /// - On deposit: immediately project shares × remaining time
    /// - On withdraw: subtract withdrawn shares × remaining time
    /// - The stored projection IS the final TWAB at round end
    /// 
    /// Round Lifecycle:
    /// 1. Round created with startTime and duration
    /// 2. Active: deposits/withdrawals adjust projections
    /// 3. Gap period: round ended but startDraw() not called yet
    /// 4. Frozen: moved to pendingDrawRound for lottery processing
    /// 5. Destroyed: after completeDraw() distributes prizes
    /// 
    /// Gap Period Handling:
    /// - Deposits after round ends but before startDraw() are tracked
    /// - Users are initialized in ended round with current shares
    /// - Next round uses lazy fallback for full-round projection
    
    access(all) resource Round {
        /// Unique identifier for this round (increments each draw).
        access(all) let roundID: UInt64
        
        /// Timestamp when this round started.
        access(all) let startTime: UFix64
        
        /// Duration of this round in seconds.
        access(all) let duration: UFix64
        
        /// Timestamp when this round ends (startTime + duration).
        access(all) let endTime: UFix64
        
        /// Projected TWAB at round end for each user.
        /// Key: receiverID, Value: projected share-seconds at round end.
        /// nil means user hasn't interacted this round (lazy initialization).
        access(self) var userProjectedTWAB: {UInt64: UFix64}
        
        /// Creates a new Round.
        /// @param roundID - Unique round identifier
        /// @param startTime - When the round starts
        /// @param duration - Round duration in seconds
        init(roundID: UInt64, startTime: UFix64, duration: UFix64) {
            self.roundID = roundID
            self.startTime = startTime
            self.duration = duration
            self.endTime = startTime + duration
            self.userProjectedTWAB = {}
        }
        
        /// Adjusts a user's projected TWAB when their shares change.
        /// 
        /// On first interaction: initializes with oldShares × duration (full round)
        /// Then adjusts: adds (shareDelta × remainingTime)
        /// 
        /// This should only be called for active rounds (not ended).
        /// 
        /// @param receiverID - User's receiver ID
        /// @param oldShares - Shares BEFORE the operation
        /// @param newShares - Shares AFTER the operation
        /// @param atTime - Current timestamp
        access(contract) fun adjustProjection(
            receiverID: UInt64,
            oldShares: UFix64,
            newShares: UFix64,
            atTime: UFix64
        ) {
            // Past round end? No adjustment needed
            if atTime >= self.endTime {
                return
            }
            
            let remainingTime = self.endTime - atTime
            
            // First interaction: initialize with full-round projection for existing shares
            if self.userProjectedTWAB[receiverID] == nil {
                self.userProjectedTWAB[receiverID] = oldShares * self.duration
            }
            
            let current = self.userProjectedTWAB[receiverID]!
            
            // Handle increase vs decrease separately (UFix64 cannot be negative)
            if newShares >= oldShares {
                // Deposit: add the increase in projected TWAB
                let shareDelta = newShares - oldShares
                self.userProjectedTWAB[receiverID] = current + (shareDelta * remainingTime)
            } else {
                // Withdrawal: subtract the decrease in projected TWAB
                let shareDelta = oldShares - newShares
                let reduction = shareDelta * remainingTime
                // Prevent underflow on the projection itself
                if current >= reduction {
                    self.userProjectedTWAB[receiverID] = current - reduction
                } else {
                    self.userProjectedTWAB[receiverID] = 0.0
                }
            }
        }
        
        /// Initializes a user's projection if not already set.
        /// Used for:
        /// - Finalizing users in an ended round (with their shares at that moment)
        /// - Initializing gap interactors in a new round
        /// 
        /// @param receiverID - User's receiver ID
        /// @param shares - User's current share balance
        access(contract) fun initializeIfNeeded(receiverID: UInt64, shares: UFix64) {
            if self.userProjectedTWAB[receiverID] == nil {
                self.userProjectedTWAB[receiverID] = shares * self.duration
            }
        }
        
        /// Returns the projected TWAB for a user.
        /// If user hasn't interacted, returns fallback based on current shares.
        /// 
        /// @param receiverID - User's receiver ID
        /// @param currentShares - User's current share balance (for fallback)
        /// @return Projected share-seconds at round end
        access(all) view fun getProjectedTWAB(receiverID: UInt64, currentShares: UFix64): UFix64 {
            if let projection = self.userProjectedTWAB[receiverID] {
                return projection
            }
            // User never interacted: they had same shares for full round
            return currentShares * self.duration
        }
        
        /// Returns whether this round has ended.
        access(all) view fun hasEnded(): Bool {
            return getCurrentBlock().timestamp >= self.endTime
        }
        
        /// Returns the round ID.
        access(all) view fun getRoundID(): UInt64 {
            return self.roundID
        }
        
        /// Returns the round start time.
        access(all) view fun getStartTime(): UFix64 {
            return self.startTime
        }
        
        /// Returns the round duration.
        access(all) view fun getDuration(): UFix64 {
            return self.duration
        }
        
        /// Returns the round end time.
        access(all) view fun getEndTime(): UFix64 {
            return self.endTime
        }
        
        /// Returns whether a user has been initialized in this round.
        access(all) view fun isUserInitialized(receiverID: UInt64): Bool {
            return self.userProjectedTWAB[receiverID] != nil
        }
        
        /// Returns the number of users with initialized projections.
        access(all) view fun getInitializedUserCount(): Int {
            return self.userProjectedTWAB.keys.length
        }
    }
    
    // ============================================================
    // SAVINGS DISTRIBUTOR RESOURCE
    // ============================================================
    
    /// ERC4626-style shares distributor with virtual offset protection against inflation attacks.
    /// 
    /// This resource manages the savings component of the prize pool:
    /// - Tracks user shares and converts between shares <-> assets
    /// - Accrues yield by increasing share price (not individual balances)
    /// 
    /// KEY CONCEPTS:
    /// 
    /// Share-Based Accounting (ERC4626):
    /// - Users receive shares proportional to their deposit
    /// - Yield increases totalAssets, which increases share price
    /// - All depositors benefit proportionally without individual updates
    /// - Virtual offsets prevent first-depositor inflation attacks
    /// 
    /// 
    /// INVARIANTS:
    /// - totalAssets should approximately equal Pool.totalStaked
    /// - sum(userShares) == totalShares
    /// - share price may increase (yield) or decrease (loss socialization)
    access(all) resource SavingsDistributor {
        /// Total shares outstanding across all users.
        access(self) var totalShares: UFix64
        
        /// Total asset value held (principal + accrued yield).
        /// This determines share price: price = (totalAssets + VIRTUAL) / (totalShares + VIRTUAL)
        access(self) var totalAssets: UFix64
        
        /// Mapping of receiverID to their share balance.
        access(self) let userShares: {UInt64: UFix64}
        
        /// Cumulative yield distributed since pool creation (for statistics).
        access(all) var totalDistributed: UFix64
        
        /// Type of fungible token vault this distributor handles.
        access(self) let vaultType: Type
        
        /// Initializes a new SavingsDistributor.
        /// @param vaultType - Type of fungible token to track
        init(vaultType: Type) {
            self.totalShares = 0.0
            self.totalAssets = 0.0
            self.userShares = {}
            self.totalDistributed = 0.0
            self.vaultType = vaultType
        }
        
        /// Accrues yield to the savings pool by increasing totalAssets.
        /// This effectively increases share price for all depositors.
        /// 
        /// A small portion ("dust") goes to virtual shares to prevent dilution attacks.
        /// The dust is proportional to VIRTUAL_SHARES / (totalShares + VIRTUAL_SHARES).
        /// 
        /// @param amount - Yield amount to accrue
        /// @return Actual amount accrued to users (after dust excluded)
        access(contract) fun accrueYield(amount: UFix64): UFix64 {
            // No yield to distribute, or no users to receive it
            if amount == 0.0 || self.totalShares == 0.0 {
                return 0.0
            }
            
            // Calculate how much goes to virtual shares (dust)
            // dustPercent = VIRTUAL_SHARES / (totalShares + VIRTUAL_SHARES)
            // This protects against inflation attacks while minimizing dilution
            let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
            let dustAmount = amount * PrizeSavings.VIRTUAL_SHARES / effectiveShares
            let actualSavings = amount - dustAmount
            
            // Increase total assets, which increases share price for everyone
            self.totalAssets = self.totalAssets + actualSavings
            self.totalDistributed = self.totalDistributed + actualSavings
            
            return actualSavings
        }
        
        /// Decreases total assets to reflect a loss in the yield source.
        /// This effectively decreases share price for all depositors proportionally.
        /// 
        /// Unlike accrueYield, this does NOT apply virtual share dust calculation
        /// because losses should be fully socialized across all depositors.
        /// 
        /// @param amount - Loss amount to socialize
        /// @return Actual amount decreased (capped at totalAssets to prevent underflow)
        access(contract) fun decreaseTotalAssets(amount: UFix64): UFix64 {
            if amount == 0.0 || self.totalAssets == 0.0 {
                return 0.0
            }
            
            // Cap at totalAssets to prevent underflow
            let actualDecrease = amount > self.totalAssets ? self.totalAssets : amount
            
            // Decrease total assets, which decreases share price for everyone
            self.totalAssets = self.totalAssets - actualDecrease
            
            // Note: We do NOT decrease totalDistributed - that's historical tracking
            // Note: We do NOT burn shares - share price naturally adjusts
            
            return actualDecrease
        }
        
        /// Records a deposit by minting shares proportional to the deposit amount.
        /// @param receiverID - User's receiver ID
        /// @param amount - Amount being deposited
        /// @return The number of shares minted
        access(contract) fun deposit(receiverID: UInt64, amount: UFix64): UFix64 {
            if amount == 0.0 {
                return 0.0
            }
            
            // Mint shares proportional to deposit at current share price
            let sharesToMint = self.convertToShares(amount)
            let currentShares = self.userShares[receiverID] ?? 0.0
            self.userShares[receiverID] = currentShares + sharesToMint
            self.totalShares = self.totalShares + sharesToMint
            self.totalAssets = self.totalAssets + amount
            
            return sharesToMint
        }
        
        /// Records a withdrawal by burning shares proportional to the withdrawal amount.
        /// @param receiverID - User's receiver ID
        /// @param amount - Amount to withdraw
        /// @return The actual amount withdrawn
        access(contract) fun withdraw(receiverID: UInt64, amount: UFix64): UFix64 {
            if amount == 0.0 {
                return 0.0
            }
            
            // Validate user has sufficient shares
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            assert(
                userShareBalance > 0.0,
                message: "SavingsDistributor.withdraw: No shares to withdraw for receiver "
                    .concat(receiverID.toString())
            )
            assert(
                self.totalShares > 0.0 && self.totalAssets > 0.0,
                message: "SavingsDistributor.withdraw: Invalid distributor state - totalShares: "
                    .concat(self.totalShares.toString())
                    .concat(", totalAssets: ").concat(self.totalAssets.toString())
            )
            
            // Validate user has sufficient balance
            let currentAssetValue = self.convertToAssets(userShareBalance)
            assert(
                amount <= currentAssetValue,
                message: "SavingsDistributor.withdraw: Insufficient balance - requested "
                    .concat(amount.toString())
                    .concat(" but receiver ").concat(receiverID.toString())
                    .concat(" only has ").concat(currentAssetValue.toString())
            )
            
            // Burn shares proportional to withdrawal at current share price
            let sharesToBurn = self.convertToShares(amount)
            
            self.userShares[receiverID] = userShareBalance - sharesToBurn
            self.totalShares = self.totalShares - sharesToBurn
            self.totalAssets = self.totalAssets - amount
            
            return amount
        }
        
        /// Returns the current share price using ERC4626-style virtual offsets.
        /// Virtual shares/assets prevent inflation attacks and ensure share price starts near 1.0.
        /// 
        /// Formula: sharePrice = (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
        /// 
        /// This protects against the "inflation attack" where the first depositor can
        /// manipulate share price by donating assets before others deposit.
        /// @return Current share price (assets per share)
        access(all) view fun getSharePrice(): UFix64 {
            let effectiveShares = self.totalShares + PrizeSavings.VIRTUAL_SHARES
            let effectiveAssets = self.totalAssets + PrizeSavings.VIRTUAL_ASSETS
            return effectiveAssets / effectiveShares
        }
        
        /// Converts an asset amount to shares at current share price.
        /// @param assets - Asset amount to convert
        /// @return Equivalent share amount
        access(all) view fun convertToShares(_ assets: UFix64): UFix64 {
            return assets / self.getSharePrice()
        }
        
        /// Converts a share amount to assets at current share price.
        /// @param shares - Share amount to convert
        /// @return Equivalent asset amount
        access(all) view fun convertToAssets(_ shares: UFix64): UFix64 {
            return shares * self.getSharePrice()
        }
        
        /// Returns the total asset value of a user's shares.
        /// @param receiverID - User's receiver ID
        /// @return User's total withdrawable balance
        access(all) view fun getUserAssetValue(receiverID: UInt64): UFix64 {
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            return self.convertToAssets(userShareBalance)
        }
        
        /// Returns cumulative yield distributed since pool creation.
        access(all) view fun getTotalDistributed(): UFix64 {
            return self.totalDistributed
        }
        
        /// Returns total shares outstanding.
        access(all) view fun getTotalShares(): UFix64 {
            return self.totalShares
        }
        
        /// Returns total assets under management.
        access(all) view fun getTotalAssets(): UFix64 {
            return self.totalAssets
        }
        
        /// Returns a user's share balance.
        /// @param receiverID - User's receiver ID
        access(all) view fun getUserShares(receiverID: UInt64): UFix64 {
            return self.userShares[receiverID] ?? 0.0
        }
    }
    
    // ============================================================
    // LOTTERY DISTRIBUTOR RESOURCE
    // ============================================================
    
    /// Manages the lottery prize pool and NFT prizes.
    /// 
    /// This resource handles:
    /// - Fungible token prize pool (accumulated from yield distribution)
    /// - Available NFT prizes (deposited by admin, awaiting draw)
    /// - Pending NFT claims (awarded to winners, awaiting user pickup)
    /// - Draw round tracking
    /// 
    /// PRIZE FLOW:
    /// 1. Yield processed → lottery portion added to prizeVault
    /// 2. NFTs deposited by admin → stored in nftPrizeSavings
    /// 3. Draw completes → prizes withdrawn and awarded
    /// 4. NFT prizes → stored in pendingNFTClaims for winner
    /// 5. Winner claims → NFT transferred to their collection
    access(all) resource LotteryDistributor {
        /// Vault holding fungible token prizes.
        /// Balance is the available prize pool for the next draw.
        access(self) var prizeVault: @{FungibleToken.Vault}
        
        /// NFTs available as prizes, keyed by NFT UUID.
        /// Admin deposits NFTs here; winner selection strategy assigns them.
        access(self) var nftPrizeSavings: @{UInt64: {NonFungibleToken.NFT}}
        
        /// NFTs awarded to winners but not yet claimed.
        /// Keyed by receiverID → array of NFTs.
        /// Winners must explicitly claim via claimPendingNFT().
        access(self) var pendingNFTClaims: @{UInt64: [{NonFungibleToken.NFT}]}
        
        /// Current draw round number (increments each completed draw).
        access(self) var _prizeRound: UInt64
        
        /// Cumulative prizes distributed since pool creation (for statistics).
        access(all) var totalPrizesDistributed: UFix64
        
        /// Returns the current draw round number.
        access(all) view fun getPrizeRound(): UInt64 {
            return self._prizeRound
        }
        
        /// Updates the draw round number.
        /// Called when a draw completes successfully.
        /// @param round - New round number
        access(contract) fun setPrizeRound(round: UInt64) {
            self._prizeRound = round
        }
        
        /// Initializes a new LotteryDistributor with an empty prize vault.
        /// @param vaultType - Type of fungible token for prizes
        init(vaultType: Type) {
            self.prizeVault <- DeFiActionsUtils.getEmptyVault(vaultType)
            self.nftPrizeSavings <- {}
            self.pendingNFTClaims <- {}
            self._prizeRound = 0
            self.totalPrizesDistributed = 0.0
        }
        
        /// Adds funds to the prize pool.
        /// Called during yield processing when lottery portion is allocated.
        /// @param vault - Vault containing funds to add
        access(contract) fun fundPrizePool(vault: @{FungibleToken.Vault}) {
            self.prizeVault.deposit(from: <- vault)
        }
        
        /// Returns the current balance of the prize pool.
        access(all) view fun getPrizePoolBalance(): UFix64 {
            return self.prizeVault.balance
        }
        
        /// Withdraws prize funds for distribution to winners.
        /// 
        /// Attempts to withdraw from yield source first (if provided), then
        /// falls back to the prize vault. This allows prizes to stay earning
        /// yield until they're actually distributed.
        /// 
        /// @param amount - Amount to withdraw
        /// @param yieldSource - Optional yield source to withdraw from first
        /// @return Vault containing the withdrawn prize
        access(contract) fun withdrawPrize(amount: UFix64, yieldSource: auth(FungibleToken.Withdraw) &{DeFiActions.Source}?): @{FungibleToken.Vault} {
            // Track cumulative prizes distributed
            self.totalPrizesDistributed = self.totalPrizesDistributed + amount
            
            var result <- DeFiActionsUtils.getEmptyVault(self.prizeVault.getType())
            
            // Try yield source first if provided
            if let source = yieldSource {
                let available = source.minimumAvailable()
                if available >= amount {
                    // Yield source can cover entire amount
                    result.deposit(from: <- source.withdrawAvailable(maxAmount: amount))
                    return <- result
                } else if available > 0.0 {
                    // Partial from yield source
                    result.deposit(from: <- source.withdrawAvailable(maxAmount: available))
                }
            }
            
            // Cover remaining from prize vault
            if result.balance < amount {
                let remaining = amount - result.balance
                assert(self.prizeVault.balance >= remaining, message: "Insufficient prize pool")
                result.deposit(from: <- self.prizeVault.withdraw(amount: remaining))
            }
            
            return <- result
        }
        
        /// Deposits an NFT to be available as a prize.
        /// @param nft - NFT resource to deposit
        access(contract) fun depositNFTPrize(nft: @{NonFungibleToken.NFT}) {
            let nftID = nft.uuid
            // Use force-move to ensure no duplicate IDs
            self.nftPrizeSavings[nftID] <-! nft
        }
        
        /// Withdraws an available NFT prize (before it's awarded).
        /// Used by admin to recover NFTs or update prize pool.
        /// @param nftID - UUID of the NFT to withdraw
        /// @return The withdrawn NFT resource
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            if let nft <- self.nftPrizeSavings.remove(key: nftID) {
                return <- nft
            }
            panic("NFT not found in prize vault: ".concat(nftID.toString()))
        }
        
        /// Stores an NFT for a winner to claim later.
        /// Used when awarding NFT prizes - we can't directly transfer to winner's
        /// collection without their active participation.
        /// @param receiverID - Winner's receiver ID
        /// @param nft - NFT to store for claiming
        access(contract) fun storePendingNFT(receiverID: UInt64, nft: @{NonFungibleToken.NFT}) {
            let nftID = nft.uuid
            
            // Initialize array if first NFT for this receiver
            if self.pendingNFTClaims[receiverID] == nil {
                self.pendingNFTClaims[receiverID] <-! []
            }
            
            // Append NFT to receiver's pending claims
            if let arrayRef = &self.pendingNFTClaims[receiverID] as auth(Mutate) &[{NonFungibleToken.NFT}]? {
                arrayRef.append(<- nft)
            } else {
                // This shouldn't happen, but handle gracefully
                destroy nft
                panic("Failed to store NFT in pending claims. NFTID: ".concat(nftID.toString()).concat(", receiverID: ").concat(receiverID.toString()))
            }
        }
        
        /// Returns the number of pending NFT claims for a receiver.
        /// @param receiverID - Receiver ID to check
        access(all) view fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.pendingNFTClaims[receiverID]?.length ?? 0
        }
        
        /// Returns the UUIDs of all pending NFT claims for a receiver.
        /// @param receiverID - Receiver ID to check
        /// @return Array of NFT UUIDs
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            if let nfts = &self.pendingNFTClaims[receiverID] as &[{NonFungibleToken.NFT}]? {
                var ids: [UInt64] = []
                for nft in nfts {
                    ids.append(nft.uuid)
                }
                return ids
            }
            return []
        }
        
        /// Returns UUIDs of all NFTs available as prizes (not yet awarded).
        access(all) view fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.nftPrizeSavings.keys
        }
        
        /// Borrows a reference to an available NFT prize (read-only).
        /// @param nftID - UUID of the NFT
        /// @return Reference to the NFT, or nil if not found
        access(all) view fun borrowNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return &self.nftPrizeSavings[nftID]
        }

        /// Claims a pending NFT and returns it to the caller.
        /// Called when a winner picks up their NFT prize.
        /// @param receiverID - Winner's receiver ID
        /// @param nftIndex - Index in the pending claims array (0-based)
        /// @return The claimed NFT resource
        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.pendingNFTClaims[receiverID] != nil: "No pending NFTs for this receiver"
                nftIndex < (self.pendingNFTClaims[receiverID]?.length ?? 0): "Invalid NFT index"
            }
            if let nftsRef = &self.pendingNFTClaims[receiverID] as auth(Remove) &[{NonFungibleToken.NFT}]? {
                return <- nftsRef.remove(at: nftIndex)
            }
            panic("Failed to access pending NFT claims. receiverID: ".concat(receiverID.toString()).concat(", nftIndex: ").concat(nftIndex.toString()))
        }
    }
    
    // ============================================================
    // PRIZE DRAW RECEIPT RESOURCE
    // ============================================================
    
    /// Represents a pending lottery draw that is waiting for randomness.
    /// 
    /// This receipt is created during startDraw() and consumed during completeDraw().
    /// It holds:
    /// - The prize amount committed for this draw
    /// - The randomness request (to be fulfilled by Flow's RandomConsumer)
    /// 
    /// NOTE: User weights are stored in BatchSelectionData resource
    /// to enable zero-copy reference passing.
    /// 
    /// SECURITY: The selection data is built during batch processing phase,
    /// so late deposits/withdrawals cannot affect lottery odds for this draw.
    access(all) resource PrizeDrawReceipt {
        /// Total prize amount committed for this draw.
        access(all) let prizeAmount: UFix64
        
        /// Pending randomness request from Flow's RandomConsumer.
        /// Set to nil after fulfillment in completeDraw().
        access(self) var request: @RandomConsumer.Request?
        
        /// Creates a new PrizeDrawReceipt.
        /// @param prizeAmount - Prize pool for this draw
        /// @param request - RandomConsumer request resource
        init(prizeAmount: UFix64, request: @RandomConsumer.Request) {
            self.prizeAmount = prizeAmount
            self.request <- request
        }
        
        /// Returns the block height where randomness was requested.
        /// Used to verify enough blocks have passed for secure randomness.
        access(all) view fun getRequestBlock(): UInt64? {
            return self.request?.block
        }
        
        /// Extracts and returns the randomness request.
        /// Called once during completeDraw() to fulfill the request.
        /// Panics if called twice (request is consumed).
        /// @return The RandomConsumer.Request resource
        access(contract) fun popRequest(): @RandomConsumer.Request {
            let request <- self.request <- nil
            if let r <- request {
                return <- r
            }
            panic("No request to pop")
        }
    }
    
    // ============================================================
    // WINNER SELECTION TYPES
    // ============================================================
    
    /// Result of a winner selection operation.
    /// Contains parallel arrays of winners, their prize amounts, and NFT assignments.
    access(all) struct WinnerSelectionResult {
        /// Array of winner receiverIDs.
        access(all) let winners: [UInt64]
        
        /// Array of prize amounts (parallel to winners array).
        access(all) let amounts: [UFix64]
        
        /// Array of NFT ID arrays (parallel to winners array).
        /// Each winner can receive multiple NFTs.
        access(all) let nftIDs: [[UInt64]]
        
        /// Creates a WinnerSelectionResult.
        /// All arrays must have the same length.
        /// @param winners - Array of winner receiverIDs
        /// @param amounts - Array of prize amounts per winner
        /// @param nftIDs - Array of NFT ID arrays per winner
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
    
    /// Configures how prizes are distributed among winners.
    /// 
    /// Implementations define:
    /// - How many winners to select
    /// - Prize amounts or percentages per winner position
    /// - NFT assignments per winner position
    /// 
    /// The actual winner SELECTION is handled by BatchSelectionData.
    /// This separation keeps distribution logic clean and testable.
    access(all) struct interface PrizeDistribution {
        
        /// Returns the number of winners this distribution needs.
        access(all) view fun getWinnerCount(): Int
        
        /// Distributes prizes among the selected winners.
        /// 
        /// @param winners - Array of winner receiverIDs (from BatchSelectionData.selectWinners)
        /// @param totalPrizeAmount - Total prize pool available
        /// @return WinnerSelectionResult with amounts and NFTs assigned to each winner
        access(all) fun distributePrizes(
            winners: [UInt64],
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult
        
        /// Returns a human-readable description of this distribution.
        access(all) view fun getDistributionName(): String
    }
    
    /// Single winner prize distribution.
    /// 
    /// The simplest distribution: one winner takes the entire prize pool.
    /// Winner selection is handled by BatchSelectionData.
    access(all) struct SingleWinnerPrize: PrizeDistribution {
        /// NFT IDs to award to the winner (all go to single winner).
        access(all) let nftIDs: [UInt64]
        
        /// Creates a SingleWinnerPrize distribution.
        /// @param nftIDs - Array of NFT UUIDs to award to winner
        init(nftIDs: [UInt64]) {
            self.nftIDs = nftIDs
        }
        
        access(all) view fun getWinnerCount(): Int {
            return 1
        }
        
        /// Distributes the entire prize to the single winner.
        access(all) fun distributePrizes(
            winners: [UInt64],
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            if winners.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            return WinnerSelectionResult(
                winners: [winners[0]],
                amounts: [totalPrizeAmount],
                nftIDs: [self.nftIDs]
            )
        }
        
        access(all) view fun getDistributionName(): String {
            return "Single Winner (100%)"
        }
    }
    
    /// Percentage-based prize distribution across multiple winners.
    /// 
    /// Distributes prizes by percentage splits. Winner selection is handled by BatchSelectionData.
    /// 
    /// Example: 3 winners with splits [0.5, 0.3, 0.2]
    /// - 1st place: 50% of prize pool
    /// - 2nd place: 30% of prize pool
    /// - 3rd place: 20% of prize pool
    access(all) struct PercentageSplit: PrizeDistribution {
        /// Prize split percentages for each winner position.
        /// Must sum to 1.0.
        access(all) let prizeSplits: [UFix64]
        
        /// NFT IDs assigned to each winner position.
        /// nftIDsPerWinner[i] = array of NFTs for winner at position i.
        access(all) let nftIDsPerWinner: [[UInt64]]
        
        /// Creates a PercentageSplit distribution.
        /// @param prizeSplits - Array of percentages summing to 1.0
        /// @param nftIDs - Array of NFT UUIDs to distribute (one per winner)
        init(prizeSplits: [UFix64], nftIDs: [UInt64]) {
            pre {
                prizeSplits.length > 0: "Must have at least one split"
            }
            
            // Validate prize splits sum to 1.0 and each is in [0, 1]
            var total: UFix64 = 0.0
            var splitIndex = 0
            for split in prizeSplits {
                assert(split >= 0.0 && split <= 1.0, message: "Each split must be between 0 and 1. split: ".concat(split.toString()).concat(", index: ").concat(splitIndex.toString()))
                total = total + split
                splitIndex = splitIndex + 1
            }
            
            assert(total == 1.0, message: "Prize splits must sum to 1.0. actual total: ".concat(total.toString()))
            
            self.prizeSplits = prizeSplits
            
            // Distribute NFTs: one per winner, in order
            var nftArray: [[UInt64]] = []
            var nftIndex = 0
            for winnerIdx in InclusiveRange(0, prizeSplits.length - 1) {
                if nftIndex < nftIDs.length {
                    nftArray.append([nftIDs[nftIndex]])
                    nftIndex = nftIndex + 1
                } else {
                    nftArray.append([])
                }
            }
            self.nftIDsPerWinner = nftArray
        }
        
        access(all) view fun getWinnerCount(): Int {
            return self.prizeSplits.length
        }
        
        /// Distributes prizes by percentage to the winners.
        access(all) fun distributePrizes(
            winners: [UInt64],
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            if winners.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Calculate prize amounts with last winner getting remainder
            var prizeAmounts: [UFix64] = []
            var nftIDsArray: [[UInt64]] = []
            var calculatedSum: UFix64 = 0.0
            
            for idx in InclusiveRange(0, winners.length - 1) {
                // Last winner gets remainder to avoid rounding errors
                if idx < winners.length - 1 {
                    let split = idx < self.prizeSplits.length ? self.prizeSplits[idx] : 0.0
                    let amount = totalPrizeAmount * split
                    prizeAmounts.append(amount)
                    calculatedSum = calculatedSum + amount
                }
                
                // Assign NFTs
                if idx < self.nftIDsPerWinner.length {
                    nftIDsArray.append(self.nftIDsPerWinner[idx])
                } else {
                    nftIDsArray.append([])
                }
            }
            
            // Last winner gets remainder
            prizeAmounts.append(totalPrizeAmount - calculatedSum)
            
            return WinnerSelectionResult(
                winners: winners,
                amounts: prizeAmounts,
                nftIDs: nftIDsArray
            )
        }
        
        access(all) view fun getDistributionName(): String {
            var name = "Split ("
            for idx in InclusiveRange(0, self.prizeSplits.length - 1) {
                if idx > 0 {
                    name = name.concat("/")
                }
                name = name.concat("\(self.prizeSplits[idx] * 100.0)%")
            }
            return name.concat(")")
        }
    }
    
    /// Defines a prize tier with fixed amount and winner count.
    /// Used by FixedAmountTiers for structured prize distribution.
    /// 
    /// Example tiers:
    /// - Grand Prize: 1 winner, 100 tokens, NFT included
    /// - First Prize: 3 winners, 50 tokens each
    /// - Consolation: 10 winners, 10 tokens each
    access(all) struct PrizeTier {
        /// Fixed prize amount for each winner in this tier.
        access(all) let prizeAmount: UFix64
        
        /// Number of winners to select for this tier.
        access(all) let winnerCount: Int
        
        /// Human-readable tier name (e.g., "Grand Prize", "Runner Up").
        access(all) let name: String
        
        /// NFT IDs to distribute in this tier (one per winner, in order).
        access(all) let nftIDs: [UInt64]
        
        /// Creates a PrizeTier.
        /// @param amount - Prize amount per winner (must be > 0)
        /// @param count - Number of winners (must be > 0)
        /// @param name - Tier name for display
        /// @param nftIDs - NFTs to award (length must be <= count)
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
    
    /// Fixed amount tier-based prize distribution.
    /// 
    /// Distributes prizes according to pre-defined tiers, each with a fixed
    /// prize amount and winner count. Unlike PercentageSplit which uses
    /// percentages, this uses absolute amounts.
    /// 
    /// Example configuration:
    /// - Tier 1: 1 winner gets 100 tokens + rare NFT
    /// - Tier 2: 3 winners get 50 tokens each
    /// - Tier 3: 10 winners get 10 tokens each
    /// 
    /// Winner selection is handled by BatchSelectionData.
    access(all) struct FixedAmountTiers: PrizeDistribution {
        /// Ordered array of prize tiers (processed in order).
        access(all) let tiers: [PrizeTier]
        
        /// Creates a FixedAmountTiers distribution.
        /// @param tiers - Array of prize tiers (must have at least one)
        init(tiers: [PrizeTier]) {
            pre {
                tiers.length > 0: "Must have at least one prize tier"
            }
            self.tiers = tiers
        }
        
        access(all) view fun getWinnerCount(): Int {
            var total = 0
            for tier in self.tiers {
                total = total + tier.winnerCount
            }
            return total
        }
        
        /// Distributes fixed amounts to winners according to tiers.
        /// Winners are assigned to tiers in order.
        access(all) fun distributePrizes(
            winners: [UInt64],
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            if winners.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Calculate total prize amount needed
            var totalNeeded: UFix64 = 0.0
            for tier in self.tiers {
                totalNeeded = totalNeeded + (tier.prizeAmount * UFix64(tier.winnerCount))
            }
            
            // Insufficient prize pool - return empty
            if totalPrizeAmount < totalNeeded {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            var allWinners: [UInt64] = []
            var allPrizes: [UFix64] = []
            var allNFTIDs: [[UInt64]] = []
            var winnerIdx = 0
            
            // Process each tier in order
            for tier in self.tiers {
                var tierWinnerCount = 0
                
                while tierWinnerCount < tier.winnerCount && winnerIdx < winners.length {
                    allWinners.append(winners[winnerIdx])
                    allPrizes.append(tier.prizeAmount)
                    
                    // Assign NFT if available for this position
                    if tierWinnerCount < tier.nftIDs.length {
                        allNFTIDs.append([tier.nftIDs[tierWinnerCount]])
                    } else {
                        allNFTIDs.append([])
                    }
                    
                    tierWinnerCount = tierWinnerCount + 1
                    winnerIdx = winnerIdx + 1
                }
            }
            
            return WinnerSelectionResult(
                winners: allWinners,
                amounts: allPrizes,
                nftIDs: allNFTIDs
            )
        }
        
        access(all) view fun getDistributionName(): String {
            var name = "Fixed Tiers ("
            for idx in InclusiveRange(0, self.tiers.length - 1) {
                if idx > 0 {
                    name = name.concat(", ")
                }
                let tier = self.tiers[idx]
                name = name.concat("\(tier.winnerCount)x \(tier.prizeAmount)")
            }
            return name.concat(")")
        }
    }
    
    // ============================================================
    // POOL CONFIGURATION
    // ============================================================
    
    /// Configuration parameters for a prize savings pool.
    /// 
    /// Contains all settings needed to operate a pool:
    /// - Asset type and yield source
    /// - Distribution and winner selection strategies
    /// - Operational parameters (minimum deposit, draw interval)
    /// - Optional integrations (winner tracker)
    /// 
    /// Most parameters can be updated by admin after pool creation.
    access(all) struct PoolConfig {
        /// Type of fungible token this pool accepts (e.g., FlowToken.Vault type).
        /// Immutable after pool creation.
        access(all) let assetType: Type
        
        /// Minimum amount required for deposits (prevents dust deposits).
        /// Can be updated by admin. Set to 0 to allow any amount.
        access(all) var minimumDeposit: UFix64
        
        /// Minimum time (seconds) between lottery draws.
        /// Determines epoch length and TWAB accumulation period.
        access(all) var drawIntervalSeconds: UFix64
        
        /// Yield source connection (implements both deposit and withdraw).
        /// Handles depositing funds to earn yield and withdrawing for prizes/redemptions.
        /// Immutable after pool creation.
        access(contract) let yieldConnector: {DeFiActions.Sink, DeFiActions.Source}
        
        /// Strategy for distributing yield between savings, lottery, and treasury.
        /// Can be updated by admin with CriticalOps entitlement.
        access(contract) var distributionStrategy: {DistributionStrategy}
        
        /// Configuration for how prizes are distributed among winners.
        /// Can be updated by admin with CriticalOps entitlement.
        access(contract) var prizeDistribution: {PrizeDistribution}
        
        /// Optional capability to winner tracker for leaderboard integration.
        /// If set, winners are recorded in the tracker after each draw.
        access(contract) var winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        
        /// Creates a new PoolConfig.
        /// @param assetType - Type of fungible token vault
        /// @param yieldConnector - DeFi connector for yield generation
        /// @param minimumDeposit - Minimum deposit amount (>= 0)
        /// @param drawIntervalSeconds - Seconds between draws (>= 1)
        /// @param distributionStrategy - Yield distribution strategy
        /// @param prizeDistribution - Prize distribution configuration
        /// @param winnerTrackerCap - Optional winner tracker capability
        init(
            assetType: Type,
            yieldConnector: {DeFiActions.Sink, DeFiActions.Source},
            minimumDeposit: UFix64,
            drawIntervalSeconds: UFix64,
            distributionStrategy: {DistributionStrategy},
            prizeDistribution: {PrizeDistribution},
            winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        ) {
            self.assetType = assetType
            self.yieldConnector = yieldConnector
            self.minimumDeposit = minimumDeposit
            self.drawIntervalSeconds = drawIntervalSeconds
            self.distributionStrategy = distributionStrategy
            self.prizeDistribution = prizeDistribution
            self.winnerTrackerCap = winnerTrackerCap
        }
        
        /// Updates the distribution strategy.
        /// @param strategy - New distribution strategy
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.distributionStrategy = strategy
        }
        
        /// Updates the prize distribution configuration.
        /// @param distribution - New prize distribution
        access(contract) fun setPrizeDistribution(distribution: {PrizeDistribution}) {
            self.prizeDistribution = distribution
        }
        
        /// Updates or removes the winner tracker capability.
        /// @param cap - New capability, or nil to disable tracking
        access(contract) fun setWinnerTrackerCap(cap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?) {
            self.winnerTrackerCap = cap
        }
        
        /// Updates the draw interval.
        /// @param interval - New interval in seconds (must be >= 1)
        access(contract) fun setDrawIntervalSeconds(interval: UFix64) {
            pre {
                interval >= 1.0: "Draw interval must be at least 1 seconds"
            }
            self.drawIntervalSeconds = interval
        }
        
        /// Updates the minimum deposit amount.
        /// @param minimum - New minimum (must be >= 0)
        access(contract) fun setMinimumDeposit(minimum: UFix64) {
            pre {
                minimum >= 0.0: "Minimum deposit cannot be negative"
            }
            self.minimumDeposit = minimum
        }
        
        /// Returns the distribution strategy name for display.
        access(all) view fun getDistributionStrategyName(): String {
            return self.distributionStrategy.getStrategyName()
        }
        
        /// Returns the prize distribution name for display.
        access(all) view fun getPrizeDistributionName(): String {
            return self.prizeDistribution.getDistributionName()
        }
        
        /// Returns whether a winner tracker is configured.
        access(all) view fun hasWinnerTracker(): Bool {
            return self.winnerTrackerCap != nil
        }
        
        /// Calculates yield distribution for a given amount.
        /// Delegates to the configured distribution strategy.
        /// @param totalAmount - Amount to distribute
        /// @return DistributionPlan with calculated amounts
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan {
            return self.distributionStrategy.calculateDistribution(totalAmount: totalAmount)
        }
    }
    
    // ============================================================
    // BATCH DRAW STATE (FUTURE SCALABILITY)
    // ============================================================
    
    /// State tracking for multi-transaction batch draws.
    /// 
    /// When user count grows large, processing all TWAB calculations in a single
    /// transaction may exceed gas limits. This struct enables breaking the draw
    /// into multiple transactions:
    /// 
    /// Resource holding lottery selection data - implemented as a resource to enable zero-copy reference passing.
    /// 
    /// Lifecycle:
    /// 1. Created at startDraw() with empty arrays
    /// 2. Built incrementally by processDrawBatch()
    /// 3. Reference passed to selectWinners() in completeDraw()
    /// 4. Destroyed after completeDraw()
    /// 
    access(all) resource BatchSelectionData {
        /// Receivers with weight > 0, in processing order
        access(contract) var receiverIDs: [UInt64]
        
        /// Parallel array: cumulative weight sums for binary search
        /// cumulativeWeights[i] = sum of weights for receivers 0..i
        access(contract) var cumulativeWeights: [UFix64]
        
        /// Total weight (cached, equals last element of cumulativeWeights)
        access(contract) var totalWeight: UFix64
        
        /// Current cursor position in registeredReceiverList
        access(contract) var cursor: Int
        
        /// Snapshot of receiver count at startDraw time.
        /// Used to determine batch completion - only process users who existed at draw start.
        /// New deposits during batch processing don't extend the batch.
        access(contract) let snapshotReceiverCount: Int
        
        init(snapshotCount: Int) {
            self.receiverIDs = []
            self.cumulativeWeights = []
            self.totalWeight = 0.0
            self.cursor = 0
            self.snapshotReceiverCount = snapshotCount
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
        }
        
        // ============================================================
        // BATCH BUILDING METHODS (called by processDrawBatch)
        // ============================================================
        
        /// Adds a receiver with their weight. Builds cumulative sum on the fly.
        /// Only adds if weight > 0.
        access(contract) fun addEntry(receiverID: UInt64, weight: UFix64) {
            if weight > 0.0 {
                self.receiverIDs.append(receiverID)
                self.totalWeight = self.totalWeight + weight
                self.cumulativeWeights.append(self.totalWeight)
            }
        }
        
        /// Sets cursor to specific position.
        access(contract) fun setCursor(_ position: Int) {
            self.cursor = position
        }
        
        // ============================================================
        // READ METHODS (for strategies via reference)
        // ============================================================
        
        access(all) view fun getCursor(): Int {
            return self.cursor
        }
        
        access(all) view fun getSnapshotReceiverCount(): Int {
            return self.snapshotReceiverCount
        }
        
        access(all) view fun getReceiverCount(): Int {
            return self.receiverIDs.length
        }
        
        access(all) view fun getTotalWeight(): UFix64 {
            return self.totalWeight
        }
        
        access(all) view fun getReceiverID(at index: Int): UInt64 {
            return self.receiverIDs[index]
        }
        
        access(all) view fun getCumulativeWeight(at index: Int): UFix64 {
            return self.cumulativeWeights[index]
        }
        
        /// Binary search: finds first index where cumulativeWeights[i] > target.
        /// Used for weighted random selection. O(log n) complexity.
        access(all) view fun findWinnerIndex(randomValue: UFix64): Int {
            if self.receiverIDs.length == 0 {
                return 0
            }
            
            var low = 0
            var high = self.receiverIDs.length - 1
            
            while low < high {
                let mid = (low + high) / 2
                if self.cumulativeWeights[mid] <= randomValue {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }
        
        /// Gets the individual weight for a receiver at a given index.
        /// (Not cumulative - the actual weight for that receiver)
        access(all) view fun getWeight(at index: Int): UFix64 {
            if index == 0 {
                return self.cumulativeWeights[0]
            }
            return self.cumulativeWeights[index] - self.cumulativeWeights[index - 1]
        }
        
        // ============================================================
        // WINNER SELECTION METHODS
        // ============================================================
        
        /// Scaling constants for random number conversion.
        /// Uses 1 billion for 9 decimal places of precision.
        access(self) let RANDOM_SCALING_FACTOR: UInt64
        access(self) let RANDOM_SCALING_DIVISOR: UFix64
        
        /// Selects winners using weighted random selection without replacement.
        /// Uses PRNG for deterministic sequence from initial seed.
        /// For single winner, pass count=1.
        /// 
        /// @param count - Number of winners to select
        /// @param randomNumber - Initial seed for PRNG
        /// @return Array of winner receiverIDs (may be shorter than count if insufficient participants)
        access(all) fun selectWinners(count: Int, randomNumber: UInt64): [UInt64] {
            let receiverCount = self.receiverIDs.length
            if receiverCount == 0 || count == 0 {
                return []
            }
            
            let actualCount = count < receiverCount ? count : receiverCount
            
            // Single participant case
            if receiverCount == 1 {
                return [self.receiverIDs[0]]
            }
            
            // Zero weight fallback: return first N participants
            if self.totalWeight == 0.0 {
                var winners: [UInt64] = []
                for idx in InclusiveRange(0, actualCount - 1) {
                    winners.append(self.receiverIDs[idx])
                }
                return winners
            }
            
            // Initialize PRNG
            let prg = self.createPRNG(seed: randomNumber)
            
            // Select winners without replacement
            var winners: [UInt64] = []
            var selectedIndices: {Int: Bool} = {}
            var remainingWeight = self.totalWeight
            
            var selected = 0
            while selected < actualCount && remainingWeight > 0.0 {
                let rng = prg.nextUInt64()
                let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
                let randomValue = scaledRandom * remainingWeight
                
                // Find winner skipping already-selected
                var runningSum: UFix64 = 0.0
                var selectedIdx = 0
                
                for i in InclusiveRange(0, receiverCount - 1) {
                    if selectedIndices[i] != nil {
                        continue
                    }
                    let weight = self.getWeight(at: i)
                    runningSum = runningSum + weight
                    if randomValue < runningSum {
                        selectedIdx = i
                        break
                    }
                }
                
                winners.append(self.receiverIDs[selectedIdx])
                let selectedWeight = self.getWeight(at: selectedIdx)
                selectedIndices[selectedIdx] = true
                remainingWeight = remainingWeight - selectedWeight
                selected = selected + 1
            }
            
            return winners
        }
        
        /// Creates a PRNG from a seed for deterministic multi-winner selection.
        access(self) fun createPRNG(seed: UInt64): Xorshift128plus.PRG {
            var randomBytes = seed.toBigEndianBytes()
            while randomBytes.length < 16 {
                randomBytes.appendAll(seed.toBigEndianBytes())
            }
            var paddedBytes: [UInt8] = []
            for idx in InclusiveRange(0, 15) {
                paddedBytes.append(randomBytes[idx % randomBytes.length])
            }
            return Xorshift128plus.PRG(sourceOfRandomness: paddedBytes, salt: [])
        }
    }
    
    // ============================================================
    // POOL RESOURCE - Core Prize Savings Pool
    // ============================================================
    
    /// The main prize savings pool resource.
    /// 
    /// Pool is the central coordinator that manages:
    /// - User deposits and withdrawals
    /// - Yield generation and distribution
    /// - Lottery draws and prize distribution
    /// - Emergency mode and health monitoring
    /// 
    /// ARCHITECTURE:
    /// Pool contains nested resources:
    /// - SavingsDistributor: Share-based accounting and TWAB tracking
    /// - LotteryDistributor: Prize pool and NFT management
    /// - RandomConsumer: On-chain randomness for fair draws
    /// 
    /// LIFECYCLE:
    /// 1. Admin creates pool with createPool()
    /// 2. Users deposit via PoolPositionCollection.deposit()
    /// 3. Yield accrues from connected DeFi source
    /// 4. syncWithYieldSource() distributes yield per strategy
    /// 5. Admin calls startDraw() → completeDraw() for lottery
    /// 6. Winners receive auto-compounded prizes
    /// 7. Users withdraw via PoolPositionCollection.withdraw()
    /// 
    /// DESTRUCTION:
    /// In Cadence 1.0+, nested resources are automatically destroyed with Pool.
    /// Order: pendingDrawReceipt → randomConsumer → savingsDistributor → lotteryDistributor
    /// Treasury should be forwarded before destruction.
    access(all) resource Pool {
        // ============================================================
        // CONFIGURATION STATE
        // ============================================================
        
        /// Pool configuration (strategies, asset type, parameters).
        access(self) var config: PoolConfig
        
        /// Unique identifier for this pool (assigned at creation).
        access(self) var poolID: UInt64
        
        // ============================================================
        // EMERGENCY STATE
        // ============================================================
        
        /// Current operational state of the pool.
        access(self) var emergencyState: PoolEmergencyState
        
        /// Human-readable reason for non-Normal state (for debugging).
        access(self) var emergencyReason: String?
        
        /// Timestamp when emergency/partial mode was activated.
        access(self) var emergencyActivatedAt: UFix64?
        
        /// Configuration for emergency behavior (thresholds, auto-recovery).
        access(self) var emergencyConfig: EmergencyConfig
        
        /// Counter for consecutive withdrawal failures (triggers emergency).
        access(self) var consecutiveWithdrawFailures: Int
        
        /// Sets the pool ID. Called once during pool creation.
        /// @param id - The unique pool identifier
        access(contract) fun setPoolID(id: UInt64) {
            self.poolID = id
        }
        
        // ============================================================
        // USER TRACKING STATE
        // ============================================================
        
        /// Mapping of receiverID to their "principal" (deposits + prizes, excludes interest).
        /// This is the "no-loss guarantee" - minimum users can withdraw.
        access(self) let receiverDeposits: {UInt64: UFix64}
        
        /// Mapping of receiverID to their lifetime lottery winnings (cumulative).
        access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
        
        /// Maps receiverID to their index in registeredReceiverList.
        /// Used for O(1) lookup and O(1) unregistration via swap-and-pop.
        access(self) var registeredReceivers: {UInt64: Int}
        
        /// Sequential list of registered receiver IDs.
        /// Used for O(n) iteration during batch processing without array allocation.
        access(self) var registeredReceiverList: [UInt64]
        
        /// Mapping of receiverID to bonus lottery weight records.
        access(self) let receiverBonusWeights: {UInt64: BonusWeightRecord}
        
        // ============================================================
        // ACCOUNTING STATE
        // ============================================================
        // 
        // KEY RELATIONSHIPS:
        // 
        // totalDeposited: Sum of user deposits + auto-compounded lottery prizes
        //   - Excludes savings interest (interest is tracked in share price)
        //   - Updated on: deposit (+), prize awarded (+), withdraw (-)
        //   - This is the "no-loss guarantee" amount
        //   
        // totalStaked: Amount of assets tracked belonging directly to users
        //   - Includes savings interest (increases with accrueYield)
        //   - Updated on: deposit (+), prize (+), savings yield (+), withdraw (-)
        //   - Excludes pending lottery prizes and treasury fees
        //   
        // 
        // ============================================================
        
        /// Sum of user deposits + auto-compounded lottery prizes.
        /// This is the "no-loss guarantee"
        access(all) var totalDeposited: UFix64
        
        /// Total amount tracked belonging directly to users.
        /// Includes deposits + won prizes + savings interest.
        access(all) var totalStaked: UFix64
        
        /// Timestamp of the last completed lottery draw.
        access(all) var lastDrawTimestamp: UFix64
        
        /// Lottery funds still earning in yield source (not yet materialized).
        /// Transferred to prize vault at draw time.
        access(all) var pendingLotteryYield: UFix64
        
        /// Treasury funds still earning in yield source (not yet materialized).
        /// Transferred to recipient or unclaimed vault at draw time.
        access(all) var pendingTreasuryYield: UFix64
        
        /// Cumulative treasury amount forwarded to recipient.
        access(all) var totalTreasuryForwarded: UFix64
        
        /// Capability to treasury recipient for forwarding at draw time.
        /// If nil, treasury goes to unclaimedTreasuryVault instead.
        access(self) var treasuryRecipientCap: Capability<&{FungibleToken.Receiver}>?
        
        /// Holds treasury funds when no recipient is configured.
        /// Admin can withdraw from this vault at any time.
        access(self) var unclaimedTreasuryVault: @{FungibleToken.Vault}
        
        // ============================================================
        // NESTED RESOURCES
        // ============================================================
        
        /// Manages savings: ERC4626-style share accounting.
        access(self) let savingsDistributor: @SavingsDistributor
        
        /// Manages lottery: prize pool, NFTs, pending claims.
        access(self) let lotteryDistributor: @LotteryDistributor
        
        /// Holds pending draw receipt during two-phase draw process.
        /// Set during startDraw(), consumed during completeDraw().
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        
        /// On-chain randomness consumer for fair lottery selection.
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        // ============================================================
        // ROUND-BASED TWAB TRACKING
        // ============================================================
        
        /// Current active round for TWAB accumulation.
        /// Deposits and withdrawals adjust projections in this round.
        access(self) var activeRound: @Round?
        
        /// Round that has ended and is being processed for the lottery draw.
        /// Created during startDraw(), destroyed during completeDraw().
        access(self) var pendingDrawRound: @Round?
        
        // ============================================================
        // BATCH PROCESSING STATE (for lottery weight capture)
        // ============================================================
        
        /// Selection data being built during batch processing.
        /// Created at startDraw(), built by processDrawBatch(),
        /// reference passed to selectWinners() in completeDraw(), then destroyed.
        /// Using a resource enables zero-copy reference passing for large datasets.
        access(self) var pendingSelectionData: @BatchSelectionData?
        
        /// Creates a new Pool.
        /// @param config - Pool configuration
        /// @param emergencyConfig - Optional emergency config (uses defaults if nil)
        init(
            config: PoolConfig, 
            emergencyConfig: EmergencyConfig?
        ) {
            self.config = config
            self.poolID = 0  // Set by setPoolID after creation
            
            // Initialize emergency state as Normal
            self.emergencyState = PoolEmergencyState.Normal
            self.emergencyReason = nil
            self.emergencyActivatedAt = nil
            self.emergencyConfig = emergencyConfig ?? PrizeSavings.createDefaultEmergencyConfig()
            self.consecutiveWithdrawFailures = 0
            
            // Initialize user tracking
            self.receiverDeposits = {}
            self.receiverTotalEarnedPrizes = {}
            self.registeredReceivers = {}
            self.registeredReceiverList = []
            self.receiverBonusWeights = {}
            
            // Initialize accounting
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lastDrawTimestamp = 0.0
            self.pendingLotteryYield = 0.0
            self.pendingTreasuryYield = 0.0
            self.totalTreasuryForwarded = 0.0
            self.treasuryRecipientCap = nil
            
            // Create vault for unclaimed treasury (when no recipient configured)
            self.unclaimedTreasuryVault <- DeFiActionsUtils.getEmptyVault(config.assetType)
            
            // Create nested resources
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            
            // Initialize draw state
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            
            // Initialize round-based TWAB tracking
            // Create initial round starting now with configured draw interval as duration
            self.activeRound <- create Round(
                roundID: 1,
                startTime: getCurrentBlock().timestamp,
                duration: config.drawIntervalSeconds
            )
            self.pendingDrawRound <- nil
            
            // Initialize selection data (nil = no batch in progress)
            self.pendingSelectionData <- nil
        }
        
        // ============================================================
        // RECEIVER REGISTRATION
        // ============================================================

        /// Registers a receiver ID with this pool.
        /// Called automatically when a user first deposits.
        /// Adds to both the index dictionary and the sequential list.
        /// @param receiverID - UUID of the PoolPositionCollection
        access(contract) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            // Store index pointing to the end of the list
            let index = self.registeredReceiverList.length
            self.registeredReceivers[receiverID] = index
            self.registeredReceiverList.append(receiverID)
        }
        
        /// Unregisters a receiver ID from this pool.
        /// Called when a user withdraws to 0 shares.
        /// Uses swap-and-pop for O(1) removal from the list.
        /// @param receiverID - UUID of the PoolPositionCollection
        access(contract) fun unregisterReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] != nil: "Receiver not registered"
            }
            
            let index = self.registeredReceivers[receiverID]!
            let lastIndex = self.registeredReceiverList.length - 1
            
            // If not the last element, swap with last
            if index != lastIndex {
                let lastReceiverID = self.registeredReceiverList[lastIndex]
                // Move last element to the removed position
                self.registeredReceiverList[index] = lastReceiverID
                // Update the moved element's index in the dictionary
                self.registeredReceivers[lastReceiverID] = index
            }
            
            // Remove last element (O(1))
            self.registeredReceiverList.removeLast()
            // Remove from dictionary
            self.registeredReceivers.remove(key: receiverID)
        }

        // ============================================================
        // EMERGENCY STATE MANAGEMENT
        // ============================================================
        
        /// Returns the current emergency state.
        access(all) view fun getEmergencyState(): PoolEmergencyState {
            return self.emergencyState
        }
        
        /// Returns the emergency configuration.
        access(all) view fun getEmergencyConfig(): EmergencyConfig {
            return self.emergencyConfig
        }
        
        /// Sets the pool state with optional reason.
        /// Handles state transition logic (reset counters on Normal).
        /// @param state - Target state
        /// @param reason - Optional reason for non-Normal states
        access(contract) fun setState(state: PoolEmergencyState, reason: String?) {
            self.emergencyState = state
            if state == PoolEmergencyState.Normal {
                // Clear emergency tracking when returning to normal
                self.emergencyReason = nil
                self.emergencyActivatedAt = nil
                self.consecutiveWithdrawFailures = 0
            } else {
                self.emergencyReason = reason
                self.emergencyActivatedAt = getCurrentBlock().timestamp
            }
        }
        
        /// Enables emergency mode (withdrawals only).
        /// @param reason - Human-readable reason
        access(contract) fun setEmergencyMode(reason: String) {
            self.emergencyState = PoolEmergencyState.EmergencyMode
            self.emergencyReason = reason
            self.emergencyActivatedAt = getCurrentBlock().timestamp
        }
        
        /// Enables partial mode (limited deposits, no draws).
        /// @param reason - Human-readable reason
        access(contract) fun setPartialMode(reason: String) {
            self.emergencyState = PoolEmergencyState.PartialMode
            self.emergencyReason = reason
            self.emergencyActivatedAt = getCurrentBlock().timestamp
        }
        
        /// Clears emergency mode and returns to Normal.
        /// Resets failure counters.
        access(contract) fun clearEmergencyMode() {
            self.emergencyState = PoolEmergencyState.Normal
            self.emergencyReason = nil
            self.emergencyActivatedAt = nil
            self.consecutiveWithdrawFailures = 0
        }
        
        /// Updates the emergency configuration.
        /// @param config - New emergency configuration
        access(contract) fun setEmergencyConfig(config: EmergencyConfig) {
            self.emergencyConfig = config
        }
        
        /// Returns true if pool is in emergency mode.
        access(all) view fun isEmergencyMode(): Bool {
            return self.emergencyState == PoolEmergencyState.EmergencyMode
        }
        
        /// Returns true if pool is in partial mode.
        access(all) view fun isPartialMode(): Bool {
            return self.emergencyState == PoolEmergencyState.PartialMode
        }
        
        /// Returns detailed emergency information if not in Normal state.
        /// Useful for debugging and monitoring.
        /// @return Dictionary with emergency details, or nil if Normal
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
        
        // ============================================================
        // HEALTH MONITORING
        // ============================================================
        
        /// Calculates a health score for the yield source (0.0 to 1.0).
        /// 
        /// Components:
        /// - Balance health (0.5): Is balance >= expected threshold?
        /// - Withdrawal success (0.5): Based on consecutive failure count
        /// 
        /// @return Health score from 0.0 (unhealthy) to 1.0 (fully healthy)
        access(contract) fun checkYieldSourceHealth(): UFix64 {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let balance = yieldSource.minimumAvailable()
            let threshold = self.getEmergencyConfig().minBalanceThreshold
            
            // Check if balance meets threshold (50% of health score)
            let balanceHealthy = balance >= self.totalStaked * threshold
            
            // Calculate withdrawal success rate (50% of health score)
            let withdrawSuccessRate = self.consecutiveWithdrawFailures == 0 ? 1.0 : 
                (1.0 / UFix64(self.consecutiveWithdrawFailures + 1))
            
            // Combine scores
            var health: UFix64 = 0.0
            if balanceHealthy { health = health + 0.5 }
            health = health + (withdrawSuccessRate * 0.5)
            return health
        }
        
        /// Checks if emergency mode should be auto-triggered.
        /// Called during withdrawals to detect yield source issues.
        /// @return true if emergency mode was triggered
        access(contract) fun checkAndAutoTriggerEmergency(): Bool {
            // Only trigger from Normal state
            if self.emergencyState != PoolEmergencyState.Normal {
                return false
            }
            
            let health = self.checkYieldSourceHealth()
            
            // Trigger on low health
            if health < self.emergencyConfig.minYieldSourceHealth {
                self.setEmergencyMode(reason: "Auto-triggered: Yield source health below threshold (\(health))")
                emit EmergencyModeAutoTriggered(
                    poolID: self.poolID,
                    reason: "Low yield source health",
                    healthScore: health,
                    timestamp: getCurrentBlock().timestamp
                )
                return true
            }
            
            // Trigger on consecutive withdrawal failures
            if self.consecutiveWithdrawFailures >= self.emergencyConfig.maxWithdrawFailures {
                self.setEmergencyMode(reason: "Auto-triggered: Multiple consecutive withdrawal failures")
                emit EmergencyModeAutoTriggered(
                    poolID: self.poolID,
                    reason: "Withdrawal failures",
                    healthScore: health,
                    timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            return false
        }
        
        /// Checks if pool should auto-recover from emergency mode.
        /// Called during withdrawals to detect improved conditions.
        /// @return true if recovery occurred
        access(contract) fun checkAndAutoRecover(): Bool {
            // Only recover from EmergencyMode
            if self.emergencyState != PoolEmergencyState.EmergencyMode {
                return false
            }
            
            // Must have auto-recovery enabled
            if !self.emergencyConfig.autoRecoveryEnabled {
                return false
            }
            
            let health = self.checkYieldSourceHealth()
            
            // Health-based recovery: yield source is fully healthy
            if health >= 0.9 {
                self.clearEmergencyMode()
                emit EmergencyModeAutoRecovered(poolID: self.poolID, reason: "Yield source recovered", healthScore: health, duration: nil, timestamp: getCurrentBlock().timestamp)
                return true
            }
            
            // Time-based recovery: only if health is above minimum threshold
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
        
        // ============================================================
        // DIRECT FUNDING (Admin Only)
        // ============================================================
        
        /// Internal implementation for admin direct funding.
        /// Routes funds to specified destination (Savings or Lottery).
        /// 
        /// For Savings: Deposits to yield source and accrues yield to share price.
        /// For Lottery: Adds directly to prize pool.
        /// 
        /// @param destination - Where to route funds (Savings or Lottery)
        /// @param from - Vault containing funds to deposit
        /// @param adminUUID - Admin resource UUID for audit trail
        /// @param purpose - Description of funding purpose
        /// @param metadata - Additional metadata key-value pairs
        access(contract) fun fundDirectInternal(
            destination: PoolFundingDestination,
            from: @{FungibleToken.Vault},
            adminUUID: UInt64,
            purpose: String,
            metadata: {String: String}
        ) {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Direct funding only in normal state. Current state: ".concat(self.emergencyState.rawValue.toString())
                from.getType() == self.config.assetType: "Invalid vault type. Expected: ".concat(self.config.assetType.identifier).concat(", got: ").concat(from.getType().identifier)
            }
            
            switch destination {
                case PoolFundingDestination.Lottery:
                    // Lottery funding goes directly to prize vault
                    self.lotteryDistributor.fundPrizePool(vault: <- from)
                    
                case PoolFundingDestination.Savings:
                    // Savings funding requires depositors to receive the yield
                    assert(
                        self.savingsDistributor.getTotalShares() > 0.0,
                        message: "Cannot fund savings with no depositors - funds would be orphaned. Amount: ".concat(from.balance.toString()).concat(", totalShares: ").concat(self.savingsDistributor.getTotalShares().toString())
                    )
                    
                    let amount = from.balance
                    
                    // Deposit to yield source to earn on the funds
                    self.config.yieldConnector.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                    destroy from
                    
                    // Accrue yield to share price (minus dust to virtual shares)
                    let actualSavings = self.savingsDistributor.accrueYield(amount: amount)
                    let dustAmount = amount - actualSavings
                    self.totalStaked = self.totalStaked + actualSavings
                    emit SavingsYieldAccrued(poolID: self.poolID, amount: actualSavings)
                    
                    // Route dust to pending treasury
                    if dustAmount > 0.0 {
                        emit SavingsRoundingDustToTreasury(poolID: self.poolID, amount: dustAmount)
                        self.pendingTreasuryYield = self.pendingTreasuryYield + dustAmount
                    }
                    
                default:
                    panic("Unsupported funding destination. Destination rawValue: ".concat(destination.rawValue.toString()))
            }
        }
        
        // ============================================================
        // CORE USER OPERATIONS
        // ============================================================
        
        /// Deposits funds for a receiver.
        /// 
        /// Called internally by PoolPositionCollection.deposit().
        /// 
        /// FLOW:
        /// 1. Validate state (not paused/emergency) and amount (>= minimum)
        /// 2. Process any pending yield rewards
        /// 3. Mint shares proportional to deposit
        /// 4. Update TWAB in active round (or mark as gap interactor if round ended)
        /// 5. Update accounting (receiverDeposits, totalDeposited, totalStaked)
        /// 6. Deposit to yield source
        /// 
        /// TWAB HANDLING:
        /// - If in active round: adjustProjection() increases projected TWAB
        /// - If in gap period (round ended, startDraw not called): finalize in ended round,
        ///   mark user for full-round initialization in next round
        /// - If pending draw exists: initialize user in that round with current shares
        /// 
        /// @param from - Vault containing funds to deposit (consumed)
        /// @param receiverID - UUID of the depositor's PoolPositionCollection
        access(contract) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive. Amount: ".concat(from.balance.toString())
                from.getType() == self.config.assetType: "Invalid vault type. Expected: ".concat(self.config.assetType.identifier).concat(", got: ").concat(from.getType().identifier)
            }
            
            // Auto-register if not registered (handles re-deposits after full withdrawal)
            if self.registeredReceivers[receiverID] == nil {
                self.registerReceiver(receiverID: receiverID)
            }

            // Enforce state-specific deposit rules
            switch self.emergencyState {
                case PoolEmergencyState.Normal:
                    // Normal: enforce minimum deposit
                    assert(from.balance >= self.config.minimumDeposit, message: "Below minimum deposit. Required: ".concat(self.config.minimumDeposit.toString()).concat(", got: ").concat(from.balance.toString()))
                case PoolEmergencyState.PartialMode:
                    // Partial: enforce deposit limit
                    let depositLimit = self.emergencyConfig.partialModeDepositLimit ?? 0.0
                    assert(depositLimit > 0.0, message: "Partial mode deposit limit not configured. ReceiverID: ".concat(receiverID.toString()))
                    assert(from.balance <= depositLimit, message: "Deposit exceeds partial mode limit. Limit: ".concat(depositLimit.toString()).concat(", got: ").concat(from.balance.toString()))
                case PoolEmergencyState.EmergencyMode:
                    // Emergency: no deposits allowed
                    panic("Deposits disabled in emergency mode. Withdrawals only. ReceiverID: ".concat(receiverID.toString()).concat(", amount: ").concat(from.balance.toString()))
                case PoolEmergencyState.Paused:
                    // Paused: nothing allowed
                    panic("Pool is paused. No operations allowed. ReceiverID: ".concat(receiverID.toString()).concat(", amount: ").concat(from.balance.toString()))
            }
            
            // Process pending yield before deposit to ensure fair share price
            if self.getAvailableYieldRewards() > 0.0 {
                self.syncWithYieldSource()
            }
            
            let amount = from.balance
            let now = getCurrentBlock().timestamp
            
            // Get current shares BEFORE the deposit for TWAB calculation
            let oldShares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            
            // Record deposit in savings distributor (mints shares)
            let newSharesMinted = self.savingsDistributor.deposit(receiverID: receiverID, amount: amount)
            let newShares = oldShares + newSharesMinted
            
            // Update TWAB in the appropriate round(s)
            // Check if we're in the gap period (active round has ended but startDraw not called)
            let inGapPeriod = self.activeRound != nil && (self.activeRound?.hasEnded() ?? false)
            
            if inGapPeriod {
                // Gap period: finalize user's TWAB in ended round with pre-transaction shares
                // New round will use lazy fallback (currentShares * duration) automatically
                if let round = &self.activeRound as &Round? {
                    round.initializeIfNeeded(receiverID: receiverID, shares: oldShares)
                }
            } else {
                // Normal: adjust active round projection
                if let round = &self.activeRound as &Round? {
                    round.adjustProjection(
                        receiverID: receiverID,
                        oldShares: oldShares,
                        newShares: newShares,
                        atTime: now
                    )
                }
            }
            
            // Also initialize in pending draw round if one exists (user interacting after startDraw)
            if let pendingRound = &self.pendingDrawRound as &Round? {
                pendingRound.initializeIfNeeded(receiverID: receiverID, shares: oldShares)
            }
            
            // Update receiver's principal (deposits + prizes)
            let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
            self.receiverDeposits[receiverID] = currentPrincipal + amount
            
            // Update pool totals
            self.totalDeposited = self.totalDeposited + amount
            self.totalStaked = self.totalStaked + amount
            
            // Deposit to yield source to start earning
            self.config.yieldConnector.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy from
            
            emit Deposited(poolID: self.poolID, receiverID: receiverID, amount: amount)
        }
        
        /// Withdraws funds for a receiver.
        /// 
        /// Called internally by PoolPositionCollection.withdraw().
        /// 
        /// FLOW:
        /// 1. Validate state (not paused) and balance (sufficient)
        /// 2. Attempt auto-recovery if in emergency mode
        /// 3. Process pending yield (if in normal mode)
        /// 4. Withdraw from yield source
        /// 5. Burn shares proportional to withdrawal
        /// 6. Update TWAB in active round (or mark as gap interactor if round ended)
        /// 7. Update accounting (receiverDeposits, totalDeposited, totalStaked)
        /// 
        /// TWAB HANDLING:
        /// - If in active round: adjustProjection() decreases projected TWAB
        /// - If in gap period: finalize in ended round, mark user for next round
        /// - If pending draw exists: initialize user in that round with pre-withdraw shares
        /// 
        /// If yield source has insufficient liquidity, returns empty vault
        /// and may trigger emergency mode.
        /// 
        /// @param amount - Amount to withdraw
        /// @param receiverID - UUID of the withdrawer's PoolPositionCollection
        /// @return Vault containing withdrawn funds (may be empty on failure)
        access(contract) fun withdraw(amount: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] != nil: "Receiver not registered. ReceiverID: ".concat(receiverID.toString())
            }
            
            // Paused pool: nothing allowed
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed. ReceiverID: ".concat(receiverID.toString()).concat(", amount: ").concat(amount.toString()))
            
            // In emergency mode, check if we can auto-recover
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let _ = self.checkAndAutoRecover()
            }
            
            // Process pending yield before withdrawal (if in normal mode)
            if self.emergencyState == PoolEmergencyState.Normal && self.getAvailableYieldRewards() > 0.0 {
                self.syncWithYieldSource()
            }
            
            // Validate user has sufficient balance
            let totalBalance = self.savingsDistributor.getUserAssetValue(receiverID: receiverID)
            assert(totalBalance >= amount, message: "Insufficient balance. You have \(totalBalance) but trying to withdraw \(amount)")
            
            // Check if yield source has sufficient liquidity
            let yieldAvailable = self.config.yieldConnector.minimumAvailable()
            
            // Handle insufficient liquidity in yield source
            if yieldAvailable < amount {
                // Track failure (only increment in Normal mode to avoid double-counting)
                let newFailureCount = self.consecutiveWithdrawFailures
                    + (self.emergencyState == PoolEmergencyState.Normal ? 1 : 0)
                
                emit WithdrawalFailure(
                    poolID: self.poolID, 
                    receiverID: receiverID, 
                    amount: amount,
                    consecutiveFailures: newFailureCount, 
                    yieldAvailable: yieldAvailable
                )
                
                // Update failure count and check for emergency trigger
                if self.emergencyState == PoolEmergencyState.Normal {
                    self.consecutiveWithdrawFailures = newFailureCount
                    let _ = self.checkAndAutoTriggerEmergency()
                }
                
                // Return empty vault - withdrawal failed
                emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: 0.0)
                return <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
            }
            
            // Attempt withdrawal from yield source
            let withdrawn <- self.config.yieldConnector.withdrawAvailable(maxAmount: amount)
            let actualWithdrawn = withdrawn.balance
            
            // Handle zero withdrawal (yield source returned nothing despite claiming availability)
            if actualWithdrawn == 0.0 {
                let newFailureCount = self.consecutiveWithdrawFailures
                    + (self.emergencyState == PoolEmergencyState.Normal ? 1 : 0)
                
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
            
            // Successful withdrawal - reset failure counter
            if self.emergencyState == PoolEmergencyState.Normal {
                self.consecutiveWithdrawFailures = 0
            }
            
            let now = getCurrentBlock().timestamp
            
            // Get current shares BEFORE the withdrawal for TWAB calculation
            let oldShares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            
            // Burn shares proportional to withdrawal
            let _ = self.savingsDistributor.withdraw(receiverID: receiverID, amount: actualWithdrawn)
            
            // Get new shares AFTER the withdrawal
            let newShares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            
            // Update TWAB in the appropriate round(s)
            // Check if we're in the gap period (active round has ended but startDraw not called)
            let inGapPeriod = self.activeRound != nil && (self.activeRound?.hasEnded() ?? false)
            
            if inGapPeriod {
                // Gap period: finalize user's TWAB in ended round with pre-transaction shares
                // New round will use lazy fallback (currentShares * duration) automatically
                if let round = &self.activeRound as &Round? {
                    round.initializeIfNeeded(receiverID: receiverID, shares: oldShares)
                }
            } else {
                // Normal: adjust active round projection
                if let round = &self.activeRound as &Round? {
                    round.adjustProjection(
                        receiverID: receiverID,
                        oldShares: oldShares,
                        newShares: newShares,
                        atTime: now
                    )
                }
            }
            
            // Also initialize in pending draw round if one exists
            if let pendingRound = &self.pendingDrawRound as &Round? {
                pendingRound.initializeIfNeeded(receiverID: receiverID, shares: oldShares)
            }
            
            // Calculate how much of withdrawal is principal vs interest
            // Interest is withdrawn first (reduces less from receiverDeposits)
            let currentPrincipal = self.receiverDeposits[receiverID] ?? 0.0
            let interestEarned: UFix64 = totalBalance > currentPrincipal ? totalBalance - currentPrincipal : 0.0
            let principalWithdrawn: UFix64 = actualWithdrawn > interestEarned ? actualWithdrawn - interestEarned : 0.0
            
            // Update receiver's principal tracking
            if principalWithdrawn > 0.0 {
                self.receiverDeposits[receiverID] = currentPrincipal - principalWithdrawn
                self.totalDeposited = self.totalDeposited - principalWithdrawn
            }
            
            // Update pool total (includes both principal and interest)
            self.totalStaked = self.totalStaked - actualWithdrawn
            
            // If user has withdrawn to 0 shares, unregister them
            // BUT NOT if a draw is in progress - unregistering during batch processing
            // would corrupt indices (swap-and-pop). Ghost users with 0 shares get 0 weight.
            // They'll be cleaned up after the draw completes.
            if newShares == 0.0 && self.pendingSelectionData == nil {
                self.unregisterReceiver(receiverID: receiverID)
            }
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: actualWithdrawn)
            return <- withdrawn
        }
        
        // ============================================================
        // YIELD SOURCE SYNCHRONIZATION
        // ============================================================
        
        /// Syncs internal accounting with the yield source balance.
        /// 
        /// Compares actual yield source balance to internal allocations and
        /// adjusts accounting to match reality. Handles both appreciation (excess)
        /// and depreciation (deficit).
        /// 
        /// ALLOCATED FUNDS:
        /// allocatedFunds = totalStaked + pendingLotteryYield + pendingTreasuryYield
        /// This must always equal the yield source balance after sync.
        /// 
        /// EXCESS (yieldBalance > allocatedFunds):
        /// 1. Calculate excess amount
        /// 2. Apply distribution strategy (savings/lottery/treasury split)
        /// 3. Accrue savings yield to share price (increases totalStaked)
        /// 4. Add lottery yield to pendingLotteryYield
        /// 5. Add treasury yield to pendingTreasuryYield
        /// 
        /// DEFICIT (yieldBalance < allocatedFunds):
        /// 1. Calculate deficit amount
        /// 2. Distribute proportionally across all allocations
        /// 3. Reduce pendingTreasuryYield first (protocol absorbs loss first)
        /// 4. Reduce pendingLotteryYield second
        /// 5. Reduce savings (share price) last - protecting user principal
        /// 
        /// Called automatically during deposits and withdrawals.
        /// Can also be called manually by admin.
        access(contract) fun syncWithYieldSource() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let allocatedFunds = self.totalStaked + self.pendingLotteryYield + self.pendingTreasuryYield
            
            // === EXCESS: Apply gains ===
            if yieldBalance > allocatedFunds {
                let excess = yieldBalance - allocatedFunds
                self.applyExcess(amount: excess)
                return
            }
            
            // === DEFICIT: Apply shortfall ===
            if yieldBalance < allocatedFunds {
                let deficit = allocatedFunds - yieldBalance
                self.applyDeficit(amount: deficit)
                return
            }
            
            // === BALANCED: Nothing to do ===
        }
        
        /// Applies excess funds (appreciation) according to the distribution strategy.
        /// 
        /// All portions stay in the yield source and are tracked via pending variables.
        /// Actual transfers happen at draw time (lottery → prize pool, treasury → recipient/vault).
        /// 
        /// @param amount - Total excess amount to distribute
        access(self) fun applyExcess(amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            // Apply distribution strategy
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: amount)
            
            var savingsDust: UFix64 = 0.0
            
            // Process savings portion - increases share price for all users
            if plan.savingsAmount > 0.0 {
                // Accrue returns actual amount after virtual share dust
                let actualSavings = self.savingsDistributor.accrueYield(amount: plan.savingsAmount)
                savingsDust = plan.savingsAmount - actualSavings
                self.totalStaked = self.totalStaked + actualSavings
                emit SavingsYieldAccrued(poolID: self.poolID, amount: actualSavings)
                
                if savingsDust > 0.0 {
                    emit SavingsRoundingDustToTreasury(poolID: self.poolID, amount: savingsDust)
                }
            }
            
            // Process lottery portion - stays in yield source until draw
            if plan.lotteryAmount > 0.0 {
                self.pendingLotteryYield = self.pendingLotteryYield + plan.lotteryAmount
                emit LotteryPrizePoolFunded(
                    poolID: self.poolID,
                    amount: plan.lotteryAmount,
                    source: "yield_pending"
                )
            }
            
            // Process treasury portion + savings dust - stays in yield source until draw
            let totalTreasuryAmount = plan.treasuryAmount + savingsDust
            if totalTreasuryAmount > 0.0 {
                self.pendingTreasuryYield = self.pendingTreasuryYield + totalTreasuryAmount
                emit TreasuryFunded(
                    poolID: self.poolID,
                    amount: totalTreasuryAmount,
                    source: "yield_pending"
                )
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: amount,
                savingsAmount: plan.savingsAmount - savingsDust,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        /// Applies a deficit (depreciation) from the yield source across the pool.
        /// 
        /// Deficit is distributed proportionally according to the distribution strategy.
        /// 
        /// Example: If strategy is 50% savings, 30% lottery, 20% treasury:
        /// - Savings absorbs: 50% of deficit
        /// - Lottery absorbs: 30% of deficit
        /// - Treasury absorbs: 20% of deficit
        /// 
        /// SHORTFALL HANDLING (priority order - protect user principal):
        /// 1. Treasury absorbs its share first (capped by pendingTreasuryYield)
        /// 2. Lottery absorbs its share + treasury shortfall (capped by pendingLotteryYield)
        /// 3. Savings absorbs remainder (share price decrease affects all users)
        /// 
        /// @param amount - Total deficit to absorb
        access(self) fun applyDeficit(amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            // Use distribution strategy to calculate proportions
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: amount)
            
            // Target losses for each allocation
            var targetTreasuryLoss = plan.treasuryAmount
            var targetLotteryLoss = plan.lotteryAmount
            var targetSavingsLoss = plan.savingsAmount
            
            // === STEP 1: Treasury absorbs first (protocol takes loss before users) ===
            var absorbedByTreasury: UFix64 = 0.0
            var treasuryShortfall: UFix64 = 0.0
            
            if targetTreasuryLoss > 0.0 {
                if self.pendingTreasuryYield >= targetTreasuryLoss {
                    absorbedByTreasury = targetTreasuryLoss
                } else {
                    absorbedByTreasury = self.pendingTreasuryYield
                    treasuryShortfall = targetTreasuryLoss - absorbedByTreasury
                }
                self.pendingTreasuryYield = self.pendingTreasuryYield - absorbedByTreasury
            }
            
            // === STEP 2: Lottery absorbs its share + treasury shortfall ===
            var absorbedByLottery: UFix64 = 0.0
            var lotteryShortfall: UFix64 = 0.0
            let totalLotteryTarget = targetLotteryLoss + treasuryShortfall
            
            if totalLotteryTarget > 0.0 {
                if self.pendingLotteryYield >= totalLotteryTarget {
                    absorbedByLottery = totalLotteryTarget
                } else {
                    absorbedByLottery = self.pendingLotteryYield
                    lotteryShortfall = totalLotteryTarget - absorbedByLottery
                }
                self.pendingLotteryYield = self.pendingLotteryYield - absorbedByLottery
            }
            
            // === STEP 3: Savings absorbs remainder (share price decrease) ===
            let totalSavingsLoss = targetSavingsLoss + lotteryShortfall
            var absorbedBySavings: UFix64 = 0.0
            
            if totalSavingsLoss > 0.0 {
                absorbedBySavings = self.savingsDistributor.decreaseTotalAssets(amount: totalSavingsLoss)
                self.totalStaked = self.totalStaked - absorbedBySavings
            }
            
            emit DeficitApplied(
                poolID: self.poolID,
                totalDeficit: amount,
                absorbedByLottery: absorbedByLottery,
                absorbedBySavings: absorbedBySavings
            )
        }
        
        // ============================================================
        // LOTTERY DRAW OPERATIONS
        // ============================================================
        
        /// Starts a lottery draw (Phase 1 of 4 - Batched Draw Process).
        /// 
        /// FLOW:
        /// 1. Validate state (Normal, no active draw, round has ended)
        /// 2. Move ended round to pendingDrawRound
        /// 3. Initialize batch capture state with receiver snapshot
        /// 4. Create new active round starting now
        /// 5. Emit NewRoundStarted event
        /// 
        /// NEXT STEPS:
        /// - Call processDrawBatch() repeatedly to capture TWAB weights
        /// - When batch complete, call requestDrawRandomness()
        /// - When randomness available, call completeDraw()
        /// 
        /// ROUND TRANSITION:
        /// - Active round (ended) → pendingDrawRound (for lottery processing)
        /// - New round created → becomes activeRound
        /// - Gap interactors handled by lazy fallback in new round
        /// 
        /// FAIRNESS: Uses projection-based share-seconds so:
        /// - More shares = more lottery weight
        /// - Longer deposits = more lottery weight
        /// - Share-based TWAB is stable against price fluctuations
        access(contract) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: \(self.emergencyState.rawValue)"
                self.pendingDrawReceipt == nil: "Draw already in progress"
                self.pendingDrawRound == nil: "Previous draw not completed"
            }
            
            // Validate round has ended (this replaces the old draw interval check)
            assert(self.canDrawNow(), message: "Round has not ended yet")
            
            // Final health check before draw
            if self.checkAndAutoTriggerEmergency() {
                panic("Emergency mode auto-triggered - cannot start draw")
            }
            
            let now = getCurrentBlock().timestamp
            
            // Get the current round's info before transitioning
            let endedRoundID = self.activeRound?.getRoundID() ?? 0
            let roundDuration = self.activeRound?.getDuration() ?? self.config.drawIntervalSeconds
            
            // Move ended round to pending draw round
            let endedRound <- self.activeRound <- nil
            self.pendingDrawRound <-! endedRound
            
            // Create selection data resource for batch processing
            // Snapshot the current receiver count - only these users will be processed
            // New deposits during batch processing won't extend the batch (prevents DoS)
            self.pendingSelectionData <-! create BatchSelectionData(
                snapshotCount: self.registeredReceiverList.length
            )
            
            // Create new round starting now
            // Gap interactors are handled by lazy fallback - no explicit initialization needed
            let newRoundID = (self.pendingDrawRound?.getRoundID() ?? 0) + 1
            let newRound <- create Round(
                roundID: newRoundID,
                startTime: now,
                duration: roundDuration
            )
            
            self.activeRound <-! newRound
            
            // Emit new round started event
            emit NewRoundStarted(
                poolID: self.poolID,
                roundID: newRoundID,
                startTime: now,
                duration: roundDuration
            )
            
            // Update last draw timestamp (draw initiated, even though batch processing pending)
            self.lastDrawTimestamp = now
            
            // Emit draw started event (weights will be captured via batch processing)
            emit DrawBatchStarted(
                poolID: self.poolID,
                endedRoundID: endedRoundID,
                newRoundID: newRoundID,
                totalReceivers: self.registeredReceiverList.length
            )
        }
        
        /// Processes a batch of receivers for weight capture (Phase 2 of 4).
        /// 
        /// Call this repeatedly until isDrawBatchComplete() returns true.
        /// Iterates directly over registeredReceiverList using selection data cursor.
        /// 
        /// FLOW:
        /// 1. Get current shares for each receiver in batch
        /// 2. Calculate TWAB from pendingDrawRound
        /// 3. Add bonus weights (scaled by round duration)
        /// 4. Build cumulative weight sums in pendingSelectionData (for binary search)
        /// 
        /// @param limit - Maximum receivers to process this batch
        /// @return Number of receivers remaining to process
        access(contract) fun processDrawBatch(limit: Int): Int {
            pre {
                self.pendingDrawRound != nil: "No draw in progress"
                self.pendingDrawReceipt == nil: "Randomness already requested"
                self.pendingSelectionData != nil: "No selection data"
                !self.isBatchComplete(): "Batch processing already complete"
            }
            
            // Get reference to selection data
            let selectionDataRef = (&self.pendingSelectionData as &BatchSelectionData?)!
            let selectionData = selectionDataRef
            
            let startCursor = selectionData.getCursor()
            let roundDuration = self.pendingDrawRound?.getDuration() ?? self.config.drawIntervalSeconds
            // Use snapshot count - only process users who existed at startDraw time
            let snapshotCount = selectionData.getSnapshotReceiverCount()
            let endIndex = startCursor + limit > snapshotCount 
                ? snapshotCount 
                : startCursor + limit
            
            // Process batch directly from registeredReceiverList
            var i = startCursor
            while i < endIndex {
                let receiverID = self.registeredReceiverList[i]
                
                // Get current shares
                let shares = self.savingsDistributor.getUserShares(receiverID: receiverID)
                
                // Get TWAB from pending draw round
                let twabStake = self.pendingDrawRound?.getProjectedTWAB(
                    receiverID: receiverID, 
                    currentShares: shares
                ) ?? 0.0
                
                // Add bonus weight (scaled by round duration)
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let scaledBonus = bonusWeight * roundDuration
                
                let totalWeight = twabStake + scaledBonus
                
                // Add entry directly to resource - builds cumulative sum on the fly
                // Only adds if weight > 0
                selectionData.addEntry(receiverID: receiverID, weight: totalWeight)
                
                i = i + 1
            }
            
            // Update cursor directly in resource
            let processed = endIndex - startCursor
            selectionData.setCursor(endIndex)
            
            // Calculate remaining based on snapshot count (not current list length)
            let remaining = snapshotCount - endIndex
            
            emit DrawBatchProcessed(
                poolID: self.poolID,
                processed: processed,
                remaining: remaining
            )
            
            return remaining
        }
        
        /// Requests randomness after batch processing is complete (Phase 3 of 4).
        /// 
        /// FLOW:
        /// 1. Validate batch processing is complete
        /// 2. Materialize pending yield from yield source
        /// 3. Request randomness from Flow's RandomConsumer
        /// 4. Create PrizeDrawReceipt with request
        /// 
        /// NOTE: Selection data (user weights) stays in pendingSelectionData resource
        /// until completeDraw(), where it's accessed via reference for zero-copy
        /// winner selection.
        /// 
        /// Must call completeDraw() after randomness is available (next block).
        access(contract) fun requestDrawRandomness() {
            pre {
                self.pendingDrawRound != nil: "No draw in progress"
                self.pendingSelectionData != nil: "No selection data"
                self.isBatchComplete(): "Batch processing not complete"
                self.pendingDrawReceipt == nil: "Randomness already requested"
            }
            
            // Materialize pending lottery funds from yield source
            if self.pendingLotteryYield > 0.0 {
                let lotteryVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: self.pendingLotteryYield)
                let actualWithdrawn = lotteryVault.balance
                self.lotteryDistributor.fundPrizePool(vault: <- lotteryVault)
                self.pendingLotteryYield = self.pendingLotteryYield - actualWithdrawn
            }
            
            // Materialize pending treasury funds from yield source
            if self.pendingTreasuryYield > 0.0 {
                let treasuryVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: self.pendingTreasuryYield)
                let actualWithdrawn = treasuryVault.balance
                self.pendingTreasuryYield = self.pendingTreasuryYield - actualWithdrawn
                
                // Forward to recipient if configured, otherwise store in unclaimed vault
                if let cap = self.treasuryRecipientCap {
                    if let recipientRef = cap.borrow() {
                        let forwardedAmount = treasuryVault.balance
                        recipientRef.deposit(from: <- treasuryVault)
                        self.totalTreasuryForwarded = self.totalTreasuryForwarded + forwardedAmount
                        emit TreasuryForwarded(
                            poolID: self.poolID,
                            amount: forwardedAmount,
                            recipient: cap.address
                        )
                    } else {
                        // Recipient capability invalid - store in unclaimed vault
                        self.unclaimedTreasuryVault.deposit(from: <- treasuryVault)
                    }
                } else {
                    // No recipient configured - store in unclaimed vault for admin withdrawal
                    self.unclaimedTreasuryVault.deposit(from: <- treasuryVault)
                }
            }
            
            // Get total weight for event (read via reference, no copy)
            let selectionDataRef = &self.pendingSelectionData as &BatchSelectionData?
            let totalWeight = selectionDataRef?.getTotalWeight() ?? 0.0
            
            let prizeAmount = self.lotteryDistributor.getPrizePoolBalance()
            assert(prizeAmount > 0.0, message: "No prize pool funds")
            
            // Request randomness (selection data stays in resource until completeDraw)
            let randomRequest <- self.randomConsumer.requestRandomness()
            let receipt <- create PrizeDrawReceipt(
                prizeAmount: prizeAmount,
                request: <- randomRequest
            )
            
            let commitBlock = receipt.getRequestBlock() ?? 0
            emit DrawRandomnessRequested(
                poolID: self.poolID,
                totalWeight: totalWeight,
                prizeAmount: prizeAmount,
                commitBlock: commitBlock
            )
            
            // Also emit the legacy event for backwards compatibility
            emit PrizeDrawCommitted(
                poolID: self.poolID,
                prizeAmount: prizeAmount,
                commitBlock: commitBlock
            )
            
            self.pendingDrawReceipt <-! receipt
        }
        
        /// Completes a lottery draw (Phase 4 of 4).
        /// 
        /// FLOW:
        /// 1. Consume PrizeDrawReceipt (must have been created by requestDrawRandomness)
        /// 2. Fulfill randomness request (secure on-chain random from previous block)
        /// 3. Apply winner selection strategy with captured weights
        /// 4. For each winner:
        ///    a. Withdraw prize from lottery pool
        ///    b. Auto-compound prize into winner's deposit (mints shares + updates TWAB)
        ///    c. Re-deposit prize to yield source (continues earning)
        ///    d. Award any NFT prizes (stored for claiming)
        /// 5. Record winners in tracker (if configured)
        /// 6. Emit PrizesAwarded event
        /// 7. Destroy pendingDrawRound (cleanup)
        /// 
        /// TWAB: Prize deposits update the active round's TWAB projections,
        /// giving winners credit for their new shares going forward.
        /// 
        /// IMPORTANT: Prizes are AUTO-COMPOUNDED into deposits, not transferred.
        /// Winners can withdraw their increased balance at any time.
        access(contract) fun completeDraw() {
            pre {
                self.pendingDrawReceipt != nil: "No draw in progress"
                self.pendingSelectionData != nil: "No selection data"
            }
            
            // Extract and consume the pending receipt
            let receipt <- self.pendingDrawReceipt <- nil
            let unwrappedReceipt <- receipt!
            let totalPrizeAmount = unwrappedReceipt.prizeAmount
            
            // Fulfill randomness request (must be different block from request)
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            
            // Get reference to selection data for zero-copy winner selection
            let selectionDataRef = (&self.pendingSelectionData as &BatchSelectionData?)!
            
            // Step 1: Select winners using BatchSelectionData (handles weighted random)
            let winnerCount = self.config.prizeDistribution.getWinnerCount()
            let winners = selectionDataRef.selectWinners(
                count: winnerCount,
                randomNumber: randomNumber
            )
            
            // Step 2: Distribute prizes using PrizeDistribution (handles amounts/NFTs)
            let selectionResult = self.config.prizeDistribution.distributePrizes(
                winners: winners,
                totalPrizeAmount: totalPrizeAmount
            )
            
            // Consume and destroy selection data (done with it)
            let usedSelectionData <- self.pendingSelectionData <- nil
            destroy usedSelectionData
            
            // Extract distribution results (winners are already selected above)
            let distributedWinners = selectionResult.winners
            let prizeAmounts = selectionResult.amounts
            let nftIDsPerWinner = selectionResult.nftIDs
            
            // Handle case of no winners (e.g., no eligible participants)
            if distributedWinners.length == 0 {
                emit PrizesAwarded(
                    poolID: self.poolID,
                    winners: [],
                    amounts: [],
                    round: self.lotteryDistributor.getPrizeRound()
                )
                // Still need to clean up the pending draw round
                let usedRound <- self.pendingDrawRound <- nil
                destroy usedRound
                return
            }
            
            // Validate parallel arrays are consistent
            assert(distributedWinners.length == prizeAmounts.length, message: "Winners and prize amounts must match")
            assert(distributedWinners.length == nftIDsPerWinner.length, message: "Winners and NFT IDs must match")
            
            // Increment draw round
            let currentRound = self.lotteryDistributor.getPrizeRound() + 1
            self.lotteryDistributor.setPrizeRound(round: currentRound)
            var totalAwarded: UFix64 = 0.0
            
            // Process each winner
            for i in InclusiveRange(0, distributedWinners.length - 1) {
                let winnerID = distributedWinners[i]
                let prizeAmount = prizeAmounts[i]
                let nftIDsForWinner = nftIDsPerWinner[i]
                
                // Withdraw prize from lottery pool
                let prizeVault <- self.lotteryDistributor.withdrawPrize(
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                // Get current shares BEFORE the prize deposit for TWAB calculation
                let oldShares = self.savingsDistributor.getUserShares(receiverID: winnerID)
                
                // AUTO-COMPOUND: Add prize to winner's deposit (mints shares)
                let newSharesMinted = self.savingsDistributor.deposit(receiverID: winnerID, amount: prizeAmount)
                let newShares = oldShares + newSharesMinted
                
                // Update TWAB in active round (prize deposits adjust projection like regular deposits)
                // Note: We're in the new round now (startDraw already transitioned)
                let now = getCurrentBlock().timestamp
                if let round = &self.activeRound as &Round? {
                    round.adjustProjection(
                        receiverID: winnerID,
                        oldShares: oldShares,
                        newShares: newShares,
                        atTime: now
                    )
                }
                
                // Update winner's principal (prizes count as deposits for no-loss guarantee)
                let currentPrincipal = self.receiverDeposits[winnerID] ?? 0.0
                self.receiverDeposits[winnerID] = currentPrincipal + prizeAmount
                
                // Update pool totals
                self.totalDeposited = self.totalDeposited + prizeAmount
                self.totalStaked = self.totalStaked + prizeAmount
                
                // Re-deposit prize to yield source (continues earning)
                self.config.yieldConnector.depositCapacity(from: &prizeVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                destroy prizeVault
                
                // Track lifetime prize winnings
                let totalPrizes = self.receiverTotalEarnedPrizes[winnerID] ?? 0.0
                self.receiverTotalEarnedPrizes[winnerID] = totalPrizes + prizeAmount
                
                // Process NFT prizes for this winner
                for nftID in nftIDsForWinner {
                    // Verify NFT is still available (might have been withdrawn)
                    let availableNFTs = self.lotteryDistributor.getAvailableNFTPrizeIDs()
                    var nftFound = false
                    for availableID in availableNFTs {
                        if availableID == nftID {
                            nftFound = true
                            break
                        }
                    }
                    
                    // Skip if NFT not found (shouldn't happen in normal operation)
                    if !nftFound {
                        continue
                    }
                    
                    // Move NFT to pending claims for winner to pick up
                    let nft <- self.lotteryDistributor.withdrawNFTPrize(nftID: nftID)
                    let nftType = nft.getType().identifier
                    self.lotteryDistributor.storePendingNFT(receiverID: winnerID, nft: <- nft)
                    
                    emit NFTPrizeStored(
                        poolID: self.poolID,
                        receiverID: winnerID,
                        nftID: nftID,
                        nftType: nftType,
                        reason: "Lottery win - round \(currentRound)"
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
            }
            
            // Record winners in external tracker (for leaderboards, analytics)
            if let trackerCap = self.config.winnerTrackerCap {
                if let trackerRef = trackerCap.borrow() {
                    for idx in InclusiveRange(0, distributedWinners.length - 1) {
                        trackerRef.recordWinner(
                            poolID: self.poolID,
                            round: currentRound,
                            winnerReceiverID: distributedWinners[idx],
                            amount: prizeAmounts[idx],
                            nftIDs: nftIDsPerWinner[idx]
                        )
                    }
                }
            }
            
            emit PrizesAwarded(
                poolID: self.poolID,
                winners: distributedWinners,
                amounts: prizeAmounts,
                round: currentRound
            )
            
            // Destroy the pending draw round - its TWAB data has been used
            let usedRound <- self.pendingDrawRound <- nil
            destroy usedRound
        }
        
        // ============================================================
        // STRATEGY AND CONFIGURATION SETTERS
        // ============================================================
        
        /// Returns the name of the current distribution strategy.
        access(all) view fun getDistributionStrategyName(): String {
            return self.config.distributionStrategy.getStrategyName()
        }
        
        /// Updates the distribution strategy. Called by Admin.
        /// @param strategy - New distribution strategy
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.config.setDistributionStrategy(strategy: strategy)
        }
        
        /// Returns the name of the current prize distribution.
        access(all) view fun getPrizeDistributionName(): String {
            return self.config.prizeDistribution.getDistributionName()
        }
        
        /// Updates the prize distribution. Called by Admin.
        /// @param distribution - New prize distribution
        access(contract) fun setPrizeDistribution(distribution: {PrizeDistribution}) {
            self.config.setPrizeDistribution(distribution: distribution)
        }
        
        /// Returns whether a winner tracker is configured.
        access(all) view fun hasWinnerTracker(): Bool {
            return self.config.winnerTrackerCap != nil
        }
        
        /// Updates the winner tracker capability. Called by Admin.
        /// @param cap - New capability, or nil to disable tracking
        access(contract) fun setWinnerTrackerCap(cap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?) {
            self.config.setWinnerTrackerCap(cap: cap)
        }
        
        /// Updates the draw interval. Cannot be changed during active draw.
        /// @param interval - New interval in seconds
        access(contract) fun setDrawIntervalSeconds(interval: UFix64) {
            assert(!self.isDrawInProgress(), message: "Cannot change draw interval during an active draw")
            self.config.setDrawIntervalSeconds(interval: interval)
        }
        
        /// Updates the minimum deposit amount.
        /// @param minimum - New minimum deposit
        access(contract) fun setMinimumDeposit(minimum: UFix64) {
            self.config.setMinimumDeposit(minimum: minimum)
        }
        
        // ============================================================
        // BONUS WEIGHT MANAGEMENT
        // ============================================================
        
        /// Sets or replaces a user's bonus lottery weight.
        /// Bonus weight is added to TWAB during draw selection.
        /// @param receiverID - User's receiver ID
        /// @param bonusWeight - Weight to assign (replaces existing)
        /// @param reason - Reason for bonus (audit trail)
        /// @param adminUUID - Admin performing the action
        access(contract) fun setBonusWeight(receiverID: UInt64, bonusWeight: UFix64, reason: String, adminUUID: UInt64) {
            let timestamp = getCurrentBlock().timestamp
            let record = BonusWeightRecord(bonusWeight: bonusWeight, reason: reason, adminUUID: adminUUID)
            self.receiverBonusWeights[receiverID] = record
            
            emit BonusLotteryWeightSet(
                poolID: self.poolID,
                receiverID: receiverID,
                bonusWeight: bonusWeight,
                reason: reason,
                adminUUID: adminUUID,
                timestamp: timestamp
            )
        }
        
        /// Adds weight to a user's existing bonus.
        /// Cumulative with any previous bonus.
        /// @param receiverID - User's receiver ID
        /// @param additionalWeight - Weight to add
        /// @param reason - Reason for addition
        /// @param adminUUID - Admin performing the action
        access(contract) fun addBonusWeight(receiverID: UInt64, additionalWeight: UFix64, reason: String, adminUUID: UInt64) {
            let timestamp = getCurrentBlock().timestamp
            let currentBonus = self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
            let newTotalBonus = currentBonus + additionalWeight
            
            let record = BonusWeightRecord(bonusWeight: newTotalBonus, reason: reason, adminUUID: adminUUID)
            self.receiverBonusWeights[receiverID] = record
            
            emit BonusLotteryWeightAdded(
                poolID: self.poolID,
                receiverID: receiverID,
                additionalWeight: additionalWeight,
                newTotalBonus: newTotalBonus,
                reason: reason,
                adminUUID: adminUUID,
                timestamp: timestamp
            )
        }
        
        /// Removes all bonus weight from a user.
        /// @param receiverID - User's receiver ID
        /// @param adminUUID - Admin performing the action
        access(contract) fun removeBonusWeight(receiverID: UInt64, adminUUID: UInt64) {
            let timestamp = getCurrentBlock().timestamp
            let previousBonus = self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
            
            let _ = self.receiverBonusWeights.remove(key: receiverID)
            
            emit BonusLotteryWeightRemoved(
                poolID: self.poolID,
                receiverID: receiverID,
                previousBonus: previousBonus,
                adminUUID: adminUUID,
                timestamp: timestamp
            )
        }
        
        /// Returns a user's current bonus weight.
        /// @param receiverID - User's receiver ID
        access(all) view fun getBonusWeight(receiverID: UInt64): UFix64 {
            return self.receiverBonusWeights[receiverID]?.bonusWeight ?? 0.0
        }
        
        /// Returns the full bonus weight record for a user.
        /// @param receiverID - User's receiver ID
        access(all) view fun getBonusWeightRecord(receiverID: UInt64): BonusWeightRecord? {
            return self.receiverBonusWeights[receiverID]
        }
        
        /// Returns list of all receiver IDs with bonus weights.
        access(all) view fun getAllBonusWeightReceivers(): [UInt64] {
            return self.receiverBonusWeights.keys
        }
        
        // ============================================================
        // NFT PRIZE MANAGEMENT
        // ============================================================
        
        /// Deposits an NFT as a prize. Called by Admin.
        /// @param nft - NFT to deposit
        access(contract) fun depositNFTPrize(nft: @{NonFungibleToken.NFT}) {
            self.lotteryDistributor.depositNFTPrize(nft: <- nft)
        }
        
        /// Withdraws an available NFT prize. Called by Admin.
        /// @param nftID - UUID of NFT to withdraw
        /// @return The withdrawn NFT
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            return <- self.lotteryDistributor.withdrawNFTPrize(nftID: nftID)
        }
        
        /// Returns UUIDs of all available NFT prizes.
        access(all) view fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.lotteryDistributor.getAvailableNFTPrizeIDs()
        }
        
        /// Borrows a reference to an available NFT prize.
        /// @param nftID - UUID of NFT
        /// @return Reference to NFT, or nil if not found
        access(all) view fun borrowAvailableNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return self.lotteryDistributor.borrowNFTPrize(nftID: nftID)
        }
        
        /// Returns count of pending NFT claims for a user.
        /// @param receiverID - User's receiver ID
        access(all) view fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.lotteryDistributor.getPendingNFTCount(receiverID: receiverID)
        }
        
        /// Returns UUIDs of pending NFT claims for a user.
        /// @param receiverID - User's receiver ID
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            return self.lotteryDistributor.getPendingNFTIDs(receiverID: receiverID)
        }
        
        /// Claims a pending NFT prize for a user.
        /// Called by PoolPositionCollection.
        /// @param receiverID - User's receiver ID
        /// @param nftIndex - Index in pending claims array
        /// @return The claimed NFT
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
        
        // ============================================================
        // DRAW TIMING
        // ============================================================

        /// Returns whether the current round has ended and a draw can start.
        /// This checks if the activeRound's end time has passed.
        access(all) view fun canDrawNow(): Bool {
            return self.activeRound?.hasEnded() ?? false
        }
        
        /// Returns the "no-loss guarantee" amount: user deposits + auto-compounded lottery prizes
        /// This is the minimum amount users can always withdraw (excludes savings interest)
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
        /// Formula: totalBalance - (deposits + prizes)
        /// Note: "principal" here includes both user deposits AND auto-compounded lottery prizes
        access(all) view fun getPendingSavingsInterest(receiverID: UInt64): UFix64 {
            let principal = self.receiverDeposits[receiverID] ?? 0.0  // deposits + prizes
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
            return self.savingsDistributor.getSharePrice()
        }
        
        /// Returns the user's projected TWAB for the current active round.
        /// @param receiverID - User's receiver ID
        /// @return Projected share-seconds at round end
        access(all) view fun getUserTimeWeightedShares(receiverID: UInt64): UFix64 {
            let shares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            if let round = &self.activeRound as &Round? {
                return round.getProjectedTWAB(receiverID: receiverID, currentShares: shares)
            }
            return 0.0
        }
        
        /// Returns the current round ID.
        access(all) view fun getCurrentRoundID(): UInt64 {
            return self.activeRound?.getRoundID() ?? 0
        }
        
        /// Returns the current round start time.
        access(all) view fun getRoundStartTime(): UFix64 {
            return self.activeRound?.getStartTime() ?? 0.0
        }
        
        /// Returns the current round end time.
        access(all) view fun getRoundEndTime(): UFix64 {
            return self.activeRound?.getEndTime() ?? 0.0
        }
        
        /// Returns the current round duration.
        access(all) view fun getRoundDuration(): UFix64 {
            return self.activeRound?.getDuration() ?? 0.0
        }
        
        /// Returns elapsed time since round started.
        access(all) view fun getRoundElapsedTime(): UFix64 {
            if let startTime = self.activeRound?.getStartTime() {
                let now = getCurrentBlock().timestamp
                if now > startTime {
                    return now - startTime
                }
            }
            return 0.0
        }
        
        /// Returns whether the active round has ended (gap period).
        access(all) view fun isRoundEnded(): Bool {
            return self.activeRound?.hasEnded() ?? false
        }
        
        /// Returns whether there's a pending draw round being processed.
        access(all) view fun isPendingDrawInProgress(): Bool {
            return self.pendingDrawRound != nil
        }
        
        /// Returns the pending draw round ID if one exists.
        access(all) view fun getPendingDrawRoundID(): UInt64? {
            return self.pendingDrawRound?.getRoundID()
        }
        
        /// Returns whether batch processing is complete (cursor has reached snapshot count).
        /// Uses snapshotReceiverCount from startDraw() - only processes users who existed then.        /// New deposits during batch processing don't extend the batch (prevents DoS).
        /// Returns true if no batch in progress (nil state = complete/not started).
        access(all) view fun isBatchComplete(): Bool {
            if let selectionDataRef = &self.pendingSelectionData as &BatchSelectionData? {
                return selectionDataRef.getCursor() >= selectionDataRef.getSnapshotReceiverCount()
            }
            return true  // No batch in progress = considered complete
        }
        
        /// Returns whether batch processing is in progress (after startDraw, before requestDrawRandomness).
        access(all) view fun isDrawBatchInProgress(): Bool {
            return self.pendingDrawRound != nil && self.pendingDrawReceipt == nil && self.pendingSelectionData != nil && !self.isBatchComplete()
        }
        
        /// Returns whether batch processing is complete and ready for randomness request.
        access(all) view fun isDrawBatchComplete(): Bool {
            return self.pendingSelectionData != nil && self.isBatchComplete() && self.pendingDrawRound != nil
        }
        
        /// Returns whether the draw is ready to complete (randomness has been requested).
        access(all) view fun isReadyForDrawCompletion(): Bool {
            return self.pendingDrawReceipt != nil
        }
        
        /// Returns batch processing progress information.
        /// Returns nil if no batch processing is in progress.
        access(all) view fun getDrawBatchProgress(): {String: AnyStruct}? {
            if let selectionDataRef = &self.pendingSelectionData as &BatchSelectionData? {
                let total = self.registeredReceiverList.length
                let processed = selectionDataRef.getCursor()
                let percentComplete: UFix64 = total > 0 
                    ? UFix64(processed) / UFix64(total) * 100.0 
                    : 100.0
                
                return {
                    "cursor": processed,
                    "total": total,
                    "remaining": total - processed,
                    "percentComplete": percentComplete,
                    "isComplete": self.isBatchComplete(),
                    "eligibleCount": selectionDataRef.getReceiverCount(),
                    "totalWeight": selectionDataRef.getTotalWeight()
                }
            }
            return nil
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
            return self.registeredReceivers[receiverID] != nil
        }
        
        access(all) view fun getRegisteredReceiverIDs(): [UInt64] {
            return self.registeredReceiverList
        }
        
        access(all) view fun getRegisteredReceiverCount(): Int {
            return self.registeredReceiverList.length
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
            // Exclude already-allocated funds (same logic as syncWithYieldSource)
            let allocatedFunds = self.totalStaked + self.pendingLotteryYield + self.pendingTreasuryYield
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

        access(all) view fun getPendingTreasuryYield(): UFix64 {
            return self.pendingTreasuryYield
        }

        access(all) view fun getUnclaimedTreasuryBalance(): UFix64 {
            return self.unclaimedTreasuryVault.balance
        }

        access(all) view fun getTreasuryRecipient(): Address? {
            return self.treasuryRecipientCap?.address
        }
        
        access(all) view fun hasTreasuryRecipient(): Bool {
            if let cap = self.treasuryRecipientCap {
                return cap.check()
            }
            return false
        }
        
        access(all) view fun getTotalTreasuryForwarded(): UFix64 {
            return self.totalTreasuryForwarded
        }
        
        /// Set treasury recipient for forwarding at draw time.
        access(contract) fun setTreasuryRecipient(cap: Capability<&{FungibleToken.Receiver}>?) {
            self.treasuryRecipientCap = cap
        }

        /// Withdraws funds from the unclaimed treasury vault.
        /// Called by Admin.withdrawUnclaimedTreasury.
        /// @param amount - Maximum amount to withdraw
        /// @return Vault containing withdrawn funds (may be less than requested)
        access(contract) fun withdrawUnclaimedTreasury(amount: UFix64): @{FungibleToken.Vault} {
            let available = self.unclaimedTreasuryVault.balance
            let withdrawAmount = amount > available ? available : amount
            return <- self.unclaimedTreasuryVault.withdraw(amount: withdrawAmount)
        }

        // ============================================================
        // ENTRY VIEW FUNCTIONS - Human-readable UI helpers
        // ============================================================
        // "Entries" represent the user's lottery weight for the current draw.
        // Formula: entries = projectedTWAB / drawInterval
        // 
        // This normalizes share-seconds to human-readable whole numbers:
        // - 10 shares at start of 7-day draw → 10 entries
        // - 10 shares deposited halfway through → 5 entries (prorated for this draw)
        // - At next round: same 10 shares → 10 entries (full period credit)
        //
        // The TWAB naturally handles:
        // - Multiple deposits at different times (weighted correctly)
        // - Partial withdrawals (reduces entry count)
        // - Share-based TWAB is stable against price fluctuations (yield/loss)
        // ============================================================
        
        /// Returns the user's projected entries for this round.
        /// Uses projection-based TWAB from the active round.
        /// Formula: projectedTWAB / roundDuration
        /// 
        /// Examples:
        /// - 10 shares at start of round → 10 entries (full round projection)
        /// - 10 shares deposited halfway through round → ~5 entries (prorated)
        /// - At next round, same 10 shares → 10 entries (full credit)
        access(all) view fun getUserEntries(receiverID: UInt64): UFix64 {
            let roundDuration = self.activeRound?.getDuration() ?? self.config.drawIntervalSeconds
            if roundDuration == 0.0 {
                return 0.0
            }
            
            let shares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            let projectedTwab = self.activeRound?.getProjectedTWAB(receiverID: receiverID, currentShares: shares) ?? 0.0
            
            return projectedTwab / roundDuration
        }
        
        /// Returns how far through the current round we are (0.0 to 1.0+).
        /// - 0.0 = round just started
        /// - 0.5 = halfway through round
        /// - 1.0 = round complete, ready for next draw
        access(all) view fun getDrawProgressPercent(): UFix64 {
            let roundDuration = self.activeRound?.getDuration() ?? self.config.drawIntervalSeconds
            if roundDuration == 0.0 {
                return 0.0
            }
            
            let elapsed = self.getRoundElapsedTime()
            return elapsed / roundDuration
        }
        
        /// Returns time remaining until round ends (in seconds).
        /// Returns 0.0 if round has ended (draw can happen now).
        access(all) view fun getTimeUntilNextDraw(): UFix64 {
            if let endTime = self.activeRound?.getEndTime() {
                let now = getCurrentBlock().timestamp
                if now >= endTime {
                    return 0.0
                }
                return endTime - now
            }
            return 0.0
        }
        
    }
    
    // ============================================================
    // POOL BALANCE STRUCT
    // ============================================================
    
    /// Represents a user's balance breakdown in a pool.
    /// Provides clear separation of deposit principal, earned prizes, and interest.
    access(all) struct PoolBalance {
        /// User deposits + auto-compounded lottery prizes.
        /// This is the "no-loss guarantee" amount - minimum user can withdraw.
        /// Decreases only on withdrawal.
        access(all) let deposits: UFix64
        
        /// Lifetime total of lottery prizes won (cumulative counter).
        /// This never decreases - useful for leaderboards and statistics.
        /// Note: Prizes are included in 'deposits' since they auto-compound.
        access(all) let totalEarnedPrizes: UFix64
        
        /// Current pending savings interest (yield earned but not yet withdrawn).
        /// This is NOT lifetime interest - it's current accrued interest.
        /// Included in next withdrawal.
        access(all) let savingsEarned: UFix64
        
        /// Total withdrawable balance: deposits + savingsEarned.
        /// This is what the user can actually withdraw right now.
        access(all) let totalBalance: UFix64
        
        /// Creates a PoolBalance summary.
        /// @param deposits - Principal amount (deposits + prizes)
        /// @param totalEarnedPrizes - Lifetime prize winnings
        /// @param savingsEarned - Current pending interest
        init(deposits: UFix64, totalEarnedPrizes: UFix64, savingsEarned: UFix64) {
            self.deposits = deposits
            self.totalEarnedPrizes = totalEarnedPrizes
            self.savingsEarned = savingsEarned
            self.totalBalance = deposits + savingsEarned
        }
    }
    
    // ============================================================
    // POOL POSITION COLLECTION RESOURCE
    // ============================================================
    
    /// User's position collection for interacting with prize savings pools.
    /// 
    /// This resource represents a user's account in the prize savings protocol.
    /// It can hold positions across multiple pools simultaneously.
    /// 
    /// ⚠️ CRITICAL SECURITY WARNING:
    /// This resource's UUID serves as the account key for ALL deposits.
    /// - All funds, shares, prizes, and NFTs are keyed to this resource's UUID
    /// - If this resource is destroyed or lost, funds become INACCESSIBLE
    /// - There is NO built-in recovery mechanism without admin intervention
    /// - Users should treat this resource like a wallet private key
    /// 
    /// USAGE:
    /// 1. Create and store: account.storage.save(<- createPoolPositionCollection(), to: path)
    /// 2. Deposit: collection.deposit(poolID: 0, from: <- vault)
    /// 3. Withdraw: let vault <- collection.withdraw(poolID: 0, amount: 10.0)
    /// 4. Claim NFTs: let nft <- collection.claimPendingNFT(poolID: 0, nftIndex: 0)
    access(all) resource PoolPositionCollection {
        /// Tracks which pools this collection is registered with.
        /// Registration happens automatically on first deposit.
        access(self) let registeredPools: {UInt64: Bool}
        
        init() {
            self.registeredPools = {}
        }
        
        /// Internal: Registers this collection with a pool.
        /// Called automatically on first deposit to that pool.
        /// @param poolID - ID of pool to register with
        access(self) fun registerWithPool(poolID: UInt64) {
            pre {
                self.registeredPools[poolID] == nil: "Already registered"
            }
            
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            // Register our UUID as the receiver ID in the pool
            poolRef.registerReceiver(receiverID: self.uuid)
            self.registeredPools[poolID] = true
        }
        
        /// Returns list of pool IDs this collection is registered with.
        access(all) view fun getRegisteredPoolIDs(): [UInt64] {
            return self.registeredPools.keys
        }
        
        /// Checks if this collection is registered with a specific pool.
        /// @param poolID - Pool ID to check
        access(all) view fun isRegisteredWithPool(poolID: UInt64): Bool {
            return self.registeredPools[poolID] == true
        }
        
        /// Deposits funds into a pool.
        /// 
        /// Automatically registers with the pool on first deposit.
        /// Requires PositionOps entitlement (user must have authorized capability).
        /// 
        /// @param poolID - ID of pool to deposit into
        /// @param from - Vault containing funds to deposit (consumed)
        access(PositionOps) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault}) {
            // Auto-register on first deposit
            if self.registeredPools[poolID] == nil {
                self.registerWithPool(poolID: poolID)
            }
            
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            // Delegate to pool's deposit function
            poolRef.deposit(from: <- from, receiverID: self.uuid)
        }
        
        /// Withdraws funds from a pool.
        /// 
        /// Can withdraw up to total balance (deposits + earned interest).
        /// May return empty vault if yield source has liquidity issues.
        /// 
        /// @param poolID - ID of pool to withdraw from
        /// @param amount - Amount to withdraw
        /// @return Vault containing withdrawn funds
        access(PositionOps) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid)
        }
        
        /// Claims a pending NFT prize.
        /// 
        /// NFT prizes won in lottery are stored in pending claims until picked up.
        /// Use getPendingNFTIDs() to see available NFTs.
        /// 
        /// @param poolID - ID of pool where NFT was won
        /// @param nftIndex - Index in pending claims array (0-based)
        /// @return The claimed NFT resource
        access(PositionOps) fun claimPendingNFT(poolID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            return <- poolRef.claimPendingNFT(receiverID: self.uuid, nftIndex: nftIndex)
        }
        
        /// Returns count of pending NFT claims for this user in a pool.
        /// @param poolID - Pool ID to check
        /// @return Number of NFTs awaiting claim
        access(all) view fun getPendingNFTCount(poolID: UInt64): Int {
            if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
                return poolRef.getPendingNFTCount(receiverID: self.uuid)
            }
            return 0
        }
        
        /// Returns UUIDs of all pending NFT claims for this user in a pool.
        /// @param poolID - Pool ID to check
        /// @return Array of NFT UUIDs
        access(all) fun getPendingNFTIDs(poolID: UInt64): [UInt64] {
            if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
                return poolRef.getPendingNFTIDs(receiverID: self.uuid)
            }
            return []
        }
        
        /// Returns this collection's receiver ID (its UUID).
        /// This is the key used to identify the user in all pools.
        access(all) view fun getReceiverID(): UInt64 {
            return self.uuid
        }
        
        /// Returns pending savings interest for this user in a pool.
        /// This is yield earned but not yet withdrawn.
        /// @param poolID - Pool ID to check
        access(all) view fun getPendingSavingsInterest(poolID: UInt64): UFix64 {
            if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
                return poolRef.getPendingSavingsInterest(receiverID: self.uuid)
            }
            return 0.0
        }
        
        /// Returns a complete balance breakdown for this user in a pool.
        /// Includes deposits, lifetime prizes, and pending interest.
        /// @param poolID - Pool ID to check
        /// @return PoolBalance struct with all balance components
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            // Return zero balance if not registered
            if self.registeredPools[poolID] == nil {
                return PoolBalance(deposits: 0.0, totalEarnedPrizes: 0.0, savingsEarned: 0.0)
            }
            
            if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
                return PoolBalance(
                    deposits: poolRef.getReceiverDeposit(receiverID: self.uuid),
                    totalEarnedPrizes: poolRef.getReceiverTotalEarnedPrizes(receiverID: self.uuid),
                    savingsEarned: poolRef.getPendingSavingsInterest(receiverID: self.uuid)
                )
            }
            return PoolBalance(deposits: 0.0, totalEarnedPrizes: 0.0, savingsEarned: 0.0)
        }
        
        /// Returns the user's projected entry count for the current draw.
        /// Entries represent lottery weight - higher entries = better odds.
        /// 
        /// Entry calculation:
        /// - Projects TWAB forward to draw end time
        /// - Normalizes by draw interval for human-readable number
        /// 
        /// Example: $10 deposited at start of 7-day draw = ~10 entries
        /// Example: $10 deposited halfway through = ~5 entries (prorated)
        /// 
        /// @param poolID - Pool ID to check
        /// @return Projected entry count
        access(all) view fun getPoolEntries(poolID: UInt64): UFix64 {
            if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
                return poolRef.getUserEntries(receiverID: self.uuid)
            }
            return 0.0
        }
    }
    
    // ============================================================
    // CONTRACT-LEVEL FUNCTIONS
    // ============================================================
    
    /// Internal: Creates a new Pool resource.
    /// Called by Admin.createPool() - not directly accessible.
    /// @param config - Pool configuration
    /// @param emergencyConfig - Optional emergency configuration
    /// @return The new pool's ID
    access(contract) fun createPool(
        config: PoolConfig,
        emergencyConfig: EmergencyConfig?
    ): UInt64 {
        let pool <- create Pool(
            config: config, 
            emergencyConfig: emergencyConfig
        )
        
        // Assign next available ID
        let poolID = self.nextPoolID
        self.nextPoolID = self.nextPoolID + 1
        
        // Set pool ID and store
        pool.setPoolID(id: poolID)
        emit PoolCreated(
            poolID: poolID,
            assetType: config.assetType.identifier,
            strategy: config.distributionStrategy.getStrategyName()
        )
        
        self.pools[poolID] <-! pool
        return poolID
    }
    
    /// Returns a read-only reference to a pool.
    /// Safe for public use - no mutation allowed.
    /// @param poolID - ID of pool to borrow
    /// @return Reference to pool, or nil if not found
    access(all) view fun borrowPool(poolID: UInt64): &Pool? {
        return &self.pools[poolID]
    }
    
    /// Internal: Returns an authorized reference to a pool.
    /// Only used by Admin operations - not publicly accessible.
    /// @param poolID - ID of pool to borrow
    /// @return Authorized reference, or nil if not found
    access(contract) fun borrowPoolInternal(_ poolID: UInt64): auth(CriticalOps, ConfigOps) &Pool? {
        return &self.pools[poolID]
    }

    /// Internal: Returns an authorized reference or panics.
    /// Reduces boilerplate for functions that require pool to exist.
    /// @param poolID - ID of pool to get
    /// @return Authorized reference (panics if not found)
    access(contract) fun getPoolInternal(_ poolID: UInt64): auth(CriticalOps, ConfigOps) &Pool {
        return (&self.pools[poolID] as auth(CriticalOps, ConfigOps) &Pool?)
            ?? panic("Cannot get Pool: Pool with ID ".concat(poolID.toString()).concat(" does not exist"))
    }
    
    /// Returns all pool IDs currently in the contract.
    access(all) view fun getAllPoolIDs(): [UInt64] {
        return self.pools.keys
    }
    
    /// Creates a new PoolPositionCollection for a user.
    /// 
    /// Users must create and store this resource to interact with pools.
    /// Typical usage:
    /// ```
    /// let collection <- PrizeSavings.createPoolPositionCollection()
    /// account.storage.save(<- collection, to: PrizeSavings.PoolPositionCollectionStoragePath)
    /// ```
    /// 
    /// @return New PoolPositionCollection resource
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    // ============================================================
    // ENTRY QUERY FUNCTIONS - Contract-level convenience accessors
    // ============================================================
    // These functions provide easy access to entry information for UI/scripts.
    // "Entries" represent the user's lottery weight for the current draw:
    // - entries = projectedTWAB / drawInterval
    // - $10 deposited at start of draw = 10 entries
    // - $10 deposited halfway through = 5 entries (prorated)
    // ============================================================
    
    /// Returns a user's projected entry count for the current draw.
    /// Convenience wrapper for scripts that have receiverID but not collection.
    /// @param poolID - Pool ID to check
    /// @param receiverID - User's receiver ID (PoolPositionCollection UUID)
    /// @return Projected entry count
    access(all) view fun getUserEntries(poolID: UInt64, receiverID: UInt64): UFix64 {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.getUserEntries(receiverID: receiverID)
        }
        return 0.0
    }
    
    /// Returns the draw progress as a percentage (0.0 to 1.0+).
    /// Values > 1.0 indicate draw is overdue.
    /// @param poolID - Pool ID to check
    /// @return Draw progress percentage
    access(all) view fun getDrawProgressPercent(poolID: UInt64): UFix64 {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.getDrawProgressPercent()
        }
        return 0.0
    }
    
    /// Returns time remaining until next draw (in seconds).
    /// Returns 0.0 if draw can happen now.
    /// @param poolID - Pool ID to check
    /// @return Seconds until next draw is available
    access(all) view fun getTimeUntilNextDraw(poolID: UInt64): UFix64 {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.getTimeUntilNextDraw()
        }
        return 0.0
    }
    
    // ============================================================
    // CONTRACT INITIALIZATION
    // ============================================================
    
    /// Contract initializer - called once when contract is deployed.
    /// Sets up constants, storage paths, and creates Admin resource.
    init() {
        // Virtual offset constants for ERC4626 inflation attack protection.
        // Using 0.0001 to minimize dilution (~0.0001%) while providing security
        self.VIRTUAL_SHARES = 0.0001
        self.VIRTUAL_ASSETS = 0.0001
        
        // Storage paths for user collections
        self.PoolPositionCollectionStoragePath = /storage/PrizeSavingsCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeSavingsCollection
        
        // Storage path for admin resource
        self.AdminStoragePath = /storage/PrizeSavingsAdmin
        
        // Initialize pool storage
        self.pools <- {}
        self.nextPoolID = 0
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}