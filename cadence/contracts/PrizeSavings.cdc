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
    /// @param poolID - Pool starting new epoch
    /// @param epochID - New epoch identifier
    /// @param startTime - Timestamp when epoch started
    access(all) event NewEpochStarted(poolID: UInt64, epochID: UInt64, startTime: UFix64)
    
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
    /// @param oldStrategy - Name of the previous winner selection strategy
    /// @param newStrategy - Name of the new winner selection strategy
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event WinnerSelectionStrategyUpdated(poolID: UInt64, oldStrategy: String, newStrategy: String, adminUUID: UInt64)
    
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
        
        /// Updates the winner selection strategy for lottery draws.
        /// @param poolID - ID of the pool to update
        /// @param newStrategy - The new winner selection strategy (e.g., single winner, multi-winner)
        access(CriticalOps) fun updatePoolWinnerSelectionStrategy(
            poolID: UInt64,
            newStrategy: {WinnerSelectionStrategy}
        ) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            
            let oldStrategyName = poolRef.getWinnerSelectionStrategyName()
            poolRef.setWinnerSelectionStrategy(strategy: newStrategy)
            let newStrategyName = newStrategy.getStrategyName()
            
            emit WinnerSelectionStrategyUpdated(
                poolID: poolID,
                oldStrategy: oldStrategyName,
                newStrategy: newStrategyName,
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
            
            poolRef.processRewards()
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
        /// Once set, treasury funds are auto-forwarded during processRewards().
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
        // For future scalability when user count grows large.
        // Breaks startDraw() into multiple transactions to avoid gas limits.
        // Flow: startDrawSnapshot() → captureStakesBatch() (repeat) → finalizeDrawStart()

        /// Step 1 of batch draw: Lock the pool and take time snapshot.
        /// Prevents deposits/withdrawals during batch processing.
        /// NOT YET IMPLEMENTED - panics if called.
        /// @param poolID - ID of the pool to start batch draw for
        access(CriticalOps) fun startPoolDrawSnapshot(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.startDrawSnapshot()
        }
        
        /// Step 2 of batch draw: Calculate stakes for a batch of users.
        /// Call repeatedly until all users are processed.
        /// NOT YET IMPLEMENTED - panics if called.
        /// @param poolID - ID of the pool
        /// @param limit - Maximum number of users to process in this batch
        access(CriticalOps) fun processPoolDrawBatch(poolID: UInt64, limit: Int) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.captureStakesBatch(limit: limit)
        }
        
        /// Step 3 of batch draw: Request randomness after all batches processed.
        /// Finalizes the draw start and commits to on-chain randomness.
        /// NOT YET IMPLEMENTED - panics if called.
        /// @param poolID - ID of the pool
        access(CriticalOps) fun finalizePoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.finalizeDrawStart()
        }

        /// Starts a lottery draw for a pool.
        /// Captures all user TWAB stakes, requests on-chain randomness, and
        /// advances to a new epoch. Must wait for randomness before completeDraw().
        /// @param poolID - ID of the pool to start draw for
        access(CriticalOps) fun startPoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.startDraw()
        }

        /// Completes a lottery draw for a pool.
        /// Fulfills randomness request, selects winners, and distributes prizes.
        /// Prizes are auto-compounded into winners' deposits.
        /// @param poolID - ID of the pool to complete draw for
        access(CriticalOps) fun completePoolDraw(poolID: UInt64) {
            let poolRef = PrizeSavings.getPoolInternal(poolID)
            poolRef.completeDraw()
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
    // SAVINGS DISTRIBUTOR RESOURCE
    // ============================================================
    
    /// ERC4626-style shares distributor with virtual offset protection against inflation attacks.
    /// 
    /// This resource manages the savings component of the prize pool:
    /// - Tracks user shares and converts between shares <-> assets
    /// - Accrues yield by increasing share price (not individual balances)
    /// - Maintains TWAB (time-weighted average shares) for fair lottery weighting
    /// 
    /// KEY CONCEPTS:
    /// 
    /// Share-Based Accounting (ERC4626):
    /// - Users receive shares proportional to their deposit
    /// - Yield increases totalAssets, which increases share price
    /// - All depositors benefit proportionally without individual updates
    /// - Virtual offsets prevent first-depositor inflation attacks
    /// 
    /// TWAB (Time-Weighted Average Shares):
    /// - Lottery weight = sum of (shares × time) over the epoch
    /// - Ensures fair lottery odds based on share ownership AND duration
    /// - Users who deposit earlier get more "share-seconds"
    /// - Uses shares for stability against price fluctuations
    /// 
    /// Epoch System:
    /// - Each lottery draw starts a new epoch
    /// - TWAB resets at epoch boundary
    /// - Users from previous epochs get fresh starts
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
        
        // ============================================================
        // TWAB TRACKING FIELDS
        // ============================================================
        
        /// Cumulative share-seconds for each user within current epoch.
        /// Uses shares directly (not asset value) for stability against price fluctuations.
        /// This means yield/loss changes don't affect accumulated lottery weight.
        access(self) let userCumulativeShareSeconds: {UInt64: UFix64}
        
        /// Timestamp of last TWAB update for each user.
        access(self) let userLastUpdateTime: {UInt64: UFix64}
        
        /// Tracks the last epoch each user participated in (receiverID -> epochID).
        /// When a user's epoch is less than currentEpochID, their cumulative share-seconds
        /// are reset on their next interaction, ensuring each lottery period starts fresh.
        access(self) let userEpochID: {UInt64: UInt64}
        
        /// Current epoch number (increments each lottery draw).
        access(self) var currentEpochID: UInt64
        
        /// Timestamp when current epoch started.
        access(self) var epochStartTime: UFix64
        
        /// Initializes a new SavingsDistributor.
        /// @param vaultType - Type of fungible token to track
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
        
        /// Calculates elapsed share-seconds since the user's last update.
        /// Uses shares directly (not asset value) for stability against price fluctuations.
        /// This means yield accrual and loss socialization don't affect lottery weight.
        /// 
        /// If user is from a previous epoch, calculates from epoch start instead.
        /// 
        /// @param receiverID - User's receiver ID
        /// @return Share-seconds elapsed since last update
        access(all) view fun getElapsedShareSeconds(receiverID: UInt64): UFix64 {
            let now = getCurrentBlock().timestamp
            let userEpoch = self.getUserEpochID(receiverID: receiverID)
            let currentShares = self.userShares[receiverID] ?? 0.0
            
            // If user is from previous epoch, their TWAB resets from epoch start
            let effectiveLastUpdate = userEpoch < self.currentEpochID 
                ? self.epochStartTime 
                : (self.userLastUpdateTime[receiverID] ?? self.epochStartTime)
            
            let elapsed = now - effectiveLastUpdate
            if elapsed <= 0.0 {
                return 0.0
            }
            
            // share-seconds = shares × time
            return currentShares * elapsed
        }
        
        /// Returns the user's accumulated share-seconds for current epoch.
        /// Returns 0 if user is from a previous epoch (would be reset on next interaction).
        /// @param receiverID - User's receiver ID
        /// @return Accumulated share-seconds (0 if epoch mismatch)
        access(all) view fun getEffectiveAccumulated(receiverID: UInt64): UFix64 {
            let userEpoch = self.getUserEpochID(receiverID: receiverID)
            if userEpoch < self.currentEpochID {
                return 0.0  // Would be reset on next accumulation
            }
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        /// Updates a user's TWAB by adding elapsed share-seconds to their cumulative total.
        /// Handles epoch transitions by resetting TWAB for users from previous epochs.
        /// 
        /// This should be called before any share-changing operation (deposit/withdraw).
        /// 
        /// @param receiverID - User's receiver ID
        access(contract) fun accumulateTime(receiverID: UInt64) {
            let userEpoch = self.getUserEpochID(receiverID: receiverID)
            
            // Handle epoch transition - reset TWAB for users from previous epochs
            if userEpoch < self.currentEpochID {
                self.userCumulativeShareSeconds[receiverID] = 0.0
                self.userEpochID[receiverID] = self.currentEpochID
                
                // If user has shares, they've been earning TWAB since epoch start
                let currentShares = self.userShares[receiverID] ?? 0.0
                if currentShares > 0.0 {
                    self.userLastUpdateTime[receiverID] = self.epochStartTime
                } else {
                    // No shares means no TWAB to accumulate
                    self.userLastUpdateTime[receiverID] = getCurrentBlock().timestamp
                    return
                }
            }
            
            // Add elapsed share-seconds to cumulative total
            let elapsed = self.getElapsedShareSeconds(receiverID: receiverID)
            if elapsed > 0.0 {
                let currentAccum = self.userCumulativeShareSeconds[receiverID] ?? 0.0
                self.userCumulativeShareSeconds[receiverID] = currentAccum + elapsed
            }
            self.userLastUpdateTime[receiverID] = getCurrentBlock().timestamp
        }
        
        /// Returns total time-weighted shares (share-seconds) for lottery weight calculation.
        /// Includes both accumulated share-seconds AND current elapsed (real-time view).
        /// @param receiverID - User's receiver ID
        /// @return Total TWAB for lottery weighting
        access(all) view fun getTimeWeightedShares(receiverID: UInt64): UFix64 {
            return self.getEffectiveAccumulated(receiverID: receiverID) 
                + self.getElapsedShareSeconds(receiverID: receiverID)
        }
        
        /// Accumulates time and returns the final time-weighted shares.
        /// Used by lottery draw to capture the final lottery weight.
        /// @param receiverID - User's receiver ID
        /// @return Final accumulated share-seconds
        access(contract) fun updateAndGetTimeWeightedShares(receiverID: UInt64): UFix64 {
            self.accumulateTime(receiverID: receiverID)
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        /// Starts a new epoch (called when lottery draw begins).
        /// All users' TWAB will reset on their next interaction.
        access(contract) fun startNewPeriod() {
            self.currentEpochID = self.currentEpochID + 1
            self.epochStartTime = getCurrentBlock().timestamp
        }
        
        /// Returns the current epoch ID.
        access(all) view fun getCurrentEpochID(): UInt64 {
            return self.currentEpochID
        }
        
        /// Returns the timestamp when current epoch started.
        access(all) view fun getEpochStartTime(): UFix64 {
            return self.epochStartTime
        }
        
        /// Records a deposit by minting shares proportional to the deposit amount.
        /// Updates TWAB before changing balance to ensure accurate time-weighting.
        /// @param receiverID - User's receiver ID
        /// @param amount - Amount being deposited
        access(contract) fun deposit(receiverID: UInt64, amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            // Capture current TWAB before balance changes
            self.accumulateTime(receiverID: receiverID)
            
            // Mint shares proportional to deposit at current share price
            let sharesToMint = self.convertToShares(amount)
            let currentShares = self.userShares[receiverID] ?? 0.0
            self.userShares[receiverID] = currentShares + sharesToMint
            self.totalShares = self.totalShares + sharesToMint
            self.totalAssets = self.totalAssets + amount
        }
        
        /// Records a withdrawal by burning shares proportional to the withdrawal amount.
        /// Updates TWAB before changing balance to ensure accurate time-weighting.
        /// @param receiverID - User's receiver ID
        /// @param amount - Amount to withdraw
        /// @return The actual amount withdrawn
        access(contract) fun withdraw(receiverID: UInt64, amount: UFix64): UFix64 {
            if amount == 0.0 {
                return 0.0
            }
            
            // Capture current TWAB before balance changes
            self.accumulateTime(receiverID: receiverID)
            
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
        
        /// Returns raw accumulated share-seconds (without considering epoch).
        /// Use getEffectiveAccumulated() for epoch-aware value.
        /// @param receiverID - User's receiver ID
        access(all) view fun getUserAccumulatedRaw(receiverID: UInt64): UFix64 {
            return self.userCumulativeShareSeconds[receiverID] ?? 0.0
        }
        
        /// Returns the user's last TWAB update timestamp.
        /// @param receiverID - User's receiver ID
        access(all) view fun getUserLastUpdateTime(receiverID: UInt64): UFix64 {
            return self.userLastUpdateTime[receiverID] ?? self.epochStartTime
        }
        
        /// Returns the user's epoch ID, or 0 if uninitialized.
        /// 0 is a sentinel: since currentEpochID >= 1, uninitialized users trigger the
        /// reset branch (0 < currentEpochID), ensuring proper state initialization.
        /// @param receiverID - User's receiver ID
        access(all) view fun getUserEpochID(receiverID: UInt64): UInt64 {
            return self.userEpochID[receiverID] ?? 0
        }
        
        /// Calculates projected share-seconds at a specific future time.
        /// Useful for previewing lottery weight at draw time.
        /// Does not modify state - pure calculation.
        /// @param receiverID - User's receiver ID
        /// @param targetTime - Target timestamp to project to
        /// @return Projected share-seconds at target time
        access(all) view fun calculateShareSecondsAtTime(receiverID: UInt64, targetTime: UFix64): UFix64 {
            let userEpoch = self.getUserEpochID(receiverID: receiverID)
            let shares = self.userShares[receiverID] ?? 0.0
            
            // User from previous epoch - calculate from epoch start
            if userEpoch < self.currentEpochID {
                if targetTime <= self.epochStartTime { return 0.0 }
                return shares * (targetTime - self.epochStartTime)
            }
            
            let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.epochStartTime
            let accumulated = self.userCumulativeShareSeconds[receiverID] ?? 0.0
            
            // If target time is before last update, we need to "rewind"
            if targetTime <= lastUpdate {
                let overdraft = lastUpdate - targetTime
                let overdraftAmount = shares * overdraft
                return accumulated >= overdraftAmount ? accumulated - overdraftAmount : 0.0
            }
            
            // Normal case: project forward from last update
            return accumulated + (shares * (targetTime - lastUpdate))
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
    /// - Snapshot of all user weights at draw start
    /// 
    /// SECURITY: The time-weighted stakes are captured at draw start, so late
    /// deposits/withdrawals cannot affect lottery odds for this draw.
    access(all) resource PrizeDrawReceipt {
        /// Total prize amount committed for this draw.
        access(all) let prizeAmount: UFix64
        
        /// Pending randomness request from Flow's RandomConsumer.
        /// Set to nil after fulfillment in completeDraw().
        access(self) var request: @RandomConsumer.Request?
        
        /// Snapshot of user lottery weights at draw start.
        /// Keys are receiverIDs, values are total weight (TWAB + bonuses).
        /// Captured at startDraw() time to prevent manipulation.
        access(all) let timeWeightedStakes: {UInt64: UFix64}
        
        /// Creates a new PrizeDrawReceipt.
        /// @param prizeAmount - Prize pool for this draw
        /// @param request - RandomConsumer request resource
        /// @param timeWeightedStakes - Snapshot of user weights
        init(prizeAmount: UFix64, request: @RandomConsumer.Request, timeWeightedStakes: {UInt64: UFix64}) {
            self.prizeAmount = prizeAmount
            self.request <- request
            self.timeWeightedStakes = timeWeightedStakes
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
        
        /// Returns the captured weight snapshot.
        access(all) view fun getTimeWeightedStakes(): {UInt64: UFix64} {
            return self.timeWeightedStakes
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
    
    /// Strategy Pattern interface for winner selection algorithms.
    /// 
    /// Implementations determine how winners are selected from weighted participants.
    /// Different strategies enable:
    /// - Single winner (all-or-nothing)
    /// - Multiple winners with percentage splits
    /// - Fixed prize tiers with multiple winners per tier
    /// 
    /// IMPORTANT: receiverWeights are NOT raw deposit balances - they represent
    /// lottery ticket weights (TWAB share-seconds + bonus weights). Higher weight
    /// = higher probability of selection.
    access(all) struct interface WinnerSelectionStrategy {
        /// Selects winners based on weighted random selection.
        /// @param randomNumber - Source of randomness from Flow's RandomConsumer
        /// @param receiverWeights - Map of receiverID to their selection weight
        ///   (share-seconds + bonuses). NOT raw deposit balances!
        /// @param totalPrizeAmount - Total prize pool to distribute
        /// @return WinnerSelectionResult with winners, amounts, and NFT assignments
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverWeights: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult
        
        /// Returns a human-readable description of this strategy.
        access(all) view fun getStrategyName(): String
    }
    
    /// Single winner selection strategy with weighted random selection.
    /// 
    /// The simplest strategy: one winner takes the entire prize pool.
    /// Winner probability is proportional to their weight in receiverWeights.
    /// 
    /// Algorithm:
    /// 1. Build cumulative sum of all weights
    /// 2. Generate random value in range [0, totalWeight)
    /// 3. Find first participant where cumulative sum > random value
    /// 
    /// Example with weights {A: 100, B: 50, C: 50}:
    /// - Total weight = 200
    /// - Cumulative sums = [100, 150, 200]
    /// - Random 75 → A wins (75 < 100)
    /// - Random 125 → B wins (100 ≤ 125 < 150)
    /// - Random 175 → C wins (150 ≤ 175 < 200)
    access(all) struct WeightedSingleWinner: WinnerSelectionStrategy {
        /// Scaling factor for converting random UInt64 to UFix64.
        /// Uses 1 billion for 9 decimal places of precision.
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        
        /// NFT IDs to award to the winner (all go to single winner).
        access(all) let nftIDs: [UInt64]
        
        /// Creates a WeightedSingleWinner strategy.
        /// @param nftIDs - Array of NFT UUIDs to award to winner
        init(nftIDs: [UInt64]) {
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
            self.nftIDs = nftIDs
        }
        
        /// Selects a single winner with probability proportional to weight.
        /// @param randomNumber - Source of randomness
        /// @param receiverWeights - Map of receiverID to weight
        /// @param totalPrizeAmount - Total prize (all goes to winner)
        /// @return WinnerSelectionResult with single winner
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverWeights: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverWeights.keys
            
            // No participants - return empty result
            if receiverIDs.length == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Single participant - they win automatically
            if receiverIDs.length == 1 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [self.nftIDs]
                )
            }
            
            // Build cumulative weight sums for binary search
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                let weight = receiverWeights[receiverID] ?? 0.0
                runningTotal = runningTotal + weight
                cumulativeSum.append(runningTotal)
            }
            
            // All weights zero - default to first participant
            if runningTotal == 0.0 {
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [self.nftIDs]
                )
            }
            
            // Scale random number to [0.0, 1.0) then to [0.0, runningTotal)
            let scaledRandom = UFix64(randomNumber % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
            let randomValue = scaledRandom * runningTotal
            
            // Find winner using cumulative sums
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
        
        access(all) view fun getStrategyName(): String {
            return "Weighted Single Winner"
        }
    }
    
    /// Multiple winner selection with configurable prize splits.
    /// 
    /// Selects N winners with each receiving a percentage of the prize pool.
    /// Winners are selected sequentially without replacement (same user can't win twice).
    /// 
    /// Example: 3 winners with splits [0.5, 0.3, 0.2]
    /// - 1st place: 50% of prize pool
    /// - 2nd place: 30% of prize pool
    /// - 3rd place: 20% of prize pool
    /// 
    /// Algorithm:
    /// 1. Uses Xorshift128+ PRNG seeded from initial randomNumber
    /// 2. For each winner position:
    ///    a. Select winner weighted by remaining participants
    ///    b. Remove winner from pool (no double wins)
    ///    c. Recalculate cumulative weights
    /// 
    /// If fewer participants than winners, all participants win proportionally.
    access(all) struct MultiWinnerSplit: WinnerSelectionStrategy {
        /// Scaling factor for UFix64 conversion (9 decimal places).
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        
        /// Number of winners to select.
        access(all) let winnerCount: Int
        
        /// Prize split percentages for each winner position.
        /// Must sum to 1.0 and have length == winnerCount.
        access(all) let prizeSplits: [UFix64]
        
        /// NFT IDs assigned to each winner position.
        /// nftIDsPerWinner[i] = array of NFTs for winner at position i.
        access(all) let nftIDsPerWinner: [[UInt64]]
        
        /// Creates a MultiWinnerSplit strategy.
        /// @param winnerCount - Number of winners to select (must be > 0)
        /// @param prizeSplits - Array of percentages summing to 1.0 (length must match winnerCount)
        /// @param nftIDs - Array of NFT UUIDs to distribute (one per winner, round-robin)
        init(winnerCount: Int, prizeSplits: [UFix64], nftIDs: [UInt64]) {
            pre {
                winnerCount > 0: "Must have at least one winner. winnerCount: ".concat(winnerCount.toString())
                prizeSplits.length == winnerCount: "Prize splits must match winner count. prizeSplits.length: ".concat(prizeSplits.length.toString()).concat(", winnerCount: ").concat(winnerCount.toString())
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
            
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
            self.winnerCount = winnerCount
            self.prizeSplits = prizeSplits
            
            // Distribute NFTs: one per winner, in order
            var nftArray: [[UInt64]] = []
            var nftIndex = 0
            for winnerIdx in InclusiveRange(0, winnerCount - 1) {
                if nftIndex < nftIDs.length {
                    nftArray.append([nftIDs[nftIndex]])
                    nftIndex = nftIndex + 1
                } else {
                    nftArray.append([])
                }
            }
            self.nftIDsPerWinner = nftArray
        }
        
        /// Selects multiple winners with prize splits.
        /// @param randomNumber - Seed for PRNG
        /// @param receiverWeights - Map of receiverID to weight
        /// @param totalPrizeAmount - Total prize to split among winners
        /// @return WinnerSelectionResult with multiple winners
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverWeights: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverWeights.keys
            let receiverCount = receiverIDs.length
            
            // No participants - empty result
            if receiverCount == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Cap winners at available participants
            let actualWinnerCount = self.winnerCount < receiverCount ? self.winnerCount : receiverCount
            
            // Single participant - they get everything
            if receiverCount == 1 {
                let nftIDsForFirst: [UInt64] = self.nftIDsPerWinner.length > 0 ? self.nftIDsPerWinner[0] : []
                return WinnerSelectionResult(
                    winners: [receiverIDs[0]],
                    amounts: [totalPrizeAmount],
                    nftIDs: [nftIDsForFirst]
                )
            }
            
            // Build initial weight structures
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            var weightsList: [UFix64] = []
            
            for receiverID in receiverIDs {
                let weight = receiverWeights[receiverID] ?? 0.0
                weightsList.append(weight)
                runningTotal = runningTotal + weight
                cumulativeSum.append(runningTotal)
            }
            
            // All weights zero - distribute uniformly to first N participants
            if runningTotal == 0.0 {
                var uniformWinners: [UInt64] = []
                var uniformAmounts: [UFix64] = []
                var uniformNFTs: [[UInt64]] = []
                var calculatedSum: UFix64 = 0.0
                
                for idx in InclusiveRange(0, actualWinnerCount - 1) {
                    uniformWinners.append(receiverIDs[idx])
                    // Last winner gets remainder to avoid rounding errors
                    if idx < actualWinnerCount - 1 {
                        let amount = totalPrizeAmount * self.prizeSplits[idx]
                        uniformAmounts.append(amount)
                        calculatedSum = calculatedSum + amount
                    }
                    if idx < self.nftIDsPerWinner.length {
                        uniformNFTs.append(self.nftIDsPerWinner[idx])
                    } else {
                        uniformNFTs.append([])
                    }
                }
                uniformAmounts.append(totalPrizeAmount - calculatedSum)
                
                return WinnerSelectionResult(
                    winners: uniformWinners,
                    amounts: uniformAmounts,
                    nftIDs: uniformNFTs
                )
            }
            
            // Initialize PRNG with seed from initial random number
            var selectedWinners: [UInt64] = []
            var remainingWeights = weightsList
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            // Pad random bytes to 16 for Xorshift128+ (requires 128 bits)
            var randomBytes = randomNumber.toBigEndianBytes()
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
            var paddedBytes: [UInt8] = []
            for padIdx in InclusiveRange(0, 15) {
                paddedBytes.append(randomBytes[padIdx % randomBytes.length])
            }
            
            let prg = Xorshift128plus.PRG(
                sourceOfRandomness: paddedBytes,
                salt: []
            )
            
            // Select winners one at a time, removing each from the pool
            var winnerIndex = 0
            while winnerIndex < actualWinnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                // Generate new random for each selection
                let rng = prg.nextUInt64()
                let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
                let randomValue = scaledRandom * remainingTotal
                
                // Find winner using cumulative sums
                var selectedIdx = 0
                for i, cumSum in remainingCumSum {
                    if randomValue < cumSum {
                        selectedIdx = i
                        break
                    }
                }
                
                // Add to winners and remove from remaining pool
                selectedWinners.append(remainingIDs[selectedIdx])
                var newRemainingIDs: [UInt64] = []
                var newRemainingWeights: [UFix64] = []
                var newCumSum: [UFix64] = []
                var newRunningTotal: UFix64 = 0.0
                
                for idx in InclusiveRange(0, remainingIDs.length - 1) {
                    if idx != selectedIdx {
                        newRemainingIDs.append(remainingIDs[idx])
                        newRemainingWeights.append(remainingWeights[idx])
                        newRunningTotal = newRunningTotal + remainingWeights[idx]
                        newCumSum.append(newRunningTotal)
                    }
                }
                
                remainingIDs = newRemainingIDs
                remainingWeights = newRemainingWeights
                remainingCumSum = newCumSum
                remainingTotal = newRunningTotal
                winnerIndex = winnerIndex + 1
            }
            
            // Calculate prize amounts with last winner getting remainder
            var prizeAmounts: [UFix64] = []
            var calculatedSum: UFix64 = 0.0
            
            if selectedWinners.length > 1 {
                for idx in InclusiveRange(0, selectedWinners.length - 2) {
                    let split = self.prizeSplits[idx]
                    let amount = totalPrizeAmount * split
                    prizeAmounts.append(amount)
                    calculatedSum = calculatedSum + amount
                }
            }
            
            // Last winner gets remainder to avoid rounding errors
            let lastPrize = totalPrizeAmount - calculatedSum
            prizeAmounts.append(lastPrize)
            
            // Sanity check: last prize shouldn't deviate too much from expected
            if selectedWinners.length == self.winnerCount {
                let expectedLast = totalPrizeAmount * self.prizeSplits[selectedWinners.length - 1]
                let deviation = lastPrize > expectedLast ? lastPrize - expectedLast : expectedLast - lastPrize
                let maxDeviation = totalPrizeAmount * 0.01  // 1% tolerance
                assert(deviation <= maxDeviation, message: "Last prize deviation too large. deviation: ".concat(deviation.toString()).concat(", maxDeviation: ").concat(maxDeviation.toString()).concat(", lastPrize: ").concat(lastPrize.toString()).concat(", expectedLast: ").concat(expectedLast.toString()))
            }
            
            // Assign NFTs to winners by position
            var nftIDsArray: [[UInt64]] = []
            for idx2 in InclusiveRange(0, selectedWinners.length - 1) {
                if idx2 < self.nftIDsPerWinner.length {
                    nftIDsArray.append(self.nftIDsPerWinner[idx2])
                } else {
                    nftIDsArray.append([])
                }
            }
            
            return WinnerSelectionResult(
                winners: selectedWinners,
                amounts: prizeAmounts,
                nftIDs: nftIDsArray
            )
        }
        
        access(all) view fun getStrategyName(): String {
            var name = "Multi-Winner (\(self.winnerCount) winners): "
            for idx in InclusiveRange(0, self.prizeSplits.length - 1) {
                if idx > 0 {
                    name = name.concat(", ")
                }
                name = name.concat("\(self.prizeSplits[idx] * 100.0)%")
            }
            return name
        }
    }
    
    /// Defines a prize tier with fixed amount and winner count.
    /// Used by FixedPrizeTiers strategy for structured prize distribution.
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
    
    /// Fixed prize tier selection strategy.
    /// 
    /// Distributes prizes according to pre-defined tiers, each with a fixed
    /// prize amount and winner count. Unlike MultiWinnerSplit which uses
    /// percentages, this uses absolute amounts.
    /// 
    /// Example configuration:
    /// - Tier 1: 1 winner gets 100 tokens + rare NFT
    /// - Tier 2: 3 winners get 50 tokens each
    /// - Tier 3: 10 winners get 10 tokens each
    /// 
    /// REQUIREMENTS:
    /// - Prize pool must be >= sum of (tier.amount × tier.winnerCount)
    /// - Participant count must be >= sum of tier.winnerCount
    /// - If requirements not met, returns empty result (no draw)
    /// 
    /// Winners are selected without replacement across tiers (no double wins).
    access(all) struct FixedPrizeTiers: WinnerSelectionStrategy {
        /// Scaling factor for UFix64 conversion.
        access(all) let RANDOM_SCALING_FACTOR: UInt64
        access(all) let RANDOM_SCALING_DIVISOR: UFix64
        
        /// Ordered array of prize tiers (processed in order).
        access(all) let tiers: [PrizeTier]
        
        /// Creates a FixedPrizeTiers strategy.
        /// @param tiers - Array of prize tiers (must have at least one)
        init(tiers: [PrizeTier]) {
            pre {
                tiers.length > 0: "Must have at least one prize tier"
            }
            self.RANDOM_SCALING_FACTOR = 1_000_000_000
            self.RANDOM_SCALING_DIVISOR = 1_000_000_000.0
            self.tiers = tiers
        }
        
        /// Selects winners for each tier.
        /// Returns empty result if insufficient prizes or participants.
        /// @param randomNumber - Seed for PRNG
        /// @param receiverWeights - Map of receiverID to weight
        /// @param totalPrizeAmount - Available prize pool
        /// @return WinnerSelectionResult with tier winners
        access(all) fun selectWinners(
            randomNumber: UInt64,
            receiverWeights: {UInt64: UFix64},
            totalPrizeAmount: UFix64
        ): WinnerSelectionResult {
            let receiverIDs = receiverWeights.keys
            let receiverCount = receiverIDs.length
            
            // No participants - empty result
            if receiverCount == 0 {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Calculate total prize amount and winners needed
            var totalNeeded: UFix64 = 0.0
            var totalWinnersNeeded = 0
            for tier in self.tiers {
                totalNeeded = totalNeeded + (tier.prizeAmount * UFix64(tier.winnerCount))
                totalWinnersNeeded = totalWinnersNeeded + tier.winnerCount
            }
            
            // Insufficient prize pool - cannot proceed
            if totalPrizeAmount < totalNeeded {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Insufficient participants - cannot fill all tiers
            if totalWinnersNeeded > receiverCount {
                return WinnerSelectionResult(winners: [], amounts: [], nftIDs: [])
            }
            
            // Build initial cumulative weight structure
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                let weight = receiverWeights[receiverID] ?? 0.0
                runningTotal = runningTotal + weight
                cumulativeSum.append(runningTotal)
            }
            
            // Initialize PRNG
            var randomBytes = randomNumber.toBigEndianBytes()
            while randomBytes.length < 16 {
                randomBytes.appendAll(randomNumber.toBigEndianBytes())
            }
            var paddedBytes: [UInt8] = []
            for padIdx in InclusiveRange(0, 15) {
                paddedBytes.append(randomBytes[padIdx % randomBytes.length])
            }
            
            let prg = Xorshift128plus.PRG(
                sourceOfRandomness: paddedBytes,
                salt: []
            )
            
            // Track results across all tiers
            var allWinners: [UInt64] = []
            var allPrizes: [UFix64] = []
            var allNFTIDs: [[UInt64]] = []
            var remainingIDs = receiverIDs
            var remainingCumSum = cumulativeSum
            var remainingTotal = runningTotal
            
            // Process each tier in order
            for tier in self.tiers {
                var tierWinnerCount = 0
                
                // Select winners for this tier
                while tierWinnerCount < tier.winnerCount && remainingIDs.length > 0 && remainingTotal > 0.0 {
                    // Generate random and scale to weight range
                    let rng = prg.nextUInt64()
                    let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
                    let randomValue = scaledRandom * remainingTotal
                    
                    // Find winner using cumulative sums
                    var selectedIdx = 0
                    for i, cumSum in remainingCumSum {
                        if randomValue < cumSum {
                            selectedIdx = i
                            break
                        }
                    }
                    
                    // Record winner with fixed tier prize
                    let winnerID = remainingIDs[selectedIdx]
                    allWinners.append(winnerID)
                    allPrizes.append(tier.prizeAmount)
                    
                    // Assign NFT if available for this position
                    if tierWinnerCount < tier.nftIDs.length {
                        allNFTIDs.append([tier.nftIDs[tierWinnerCount]])
                    } else {
                        allNFTIDs.append([])
                    }
                    
                    // Remove winner from remaining pool
                    var newRemainingIDs: [UInt64] = []
                    var newRemainingCumSum: [UFix64] = []
                    var newRunningTotal: UFix64 = 0.0
                    
                    for oldIdx in InclusiveRange(0, remainingIDs.length - 1) {
                        if oldIdx != selectedIdx {
                            newRemainingIDs.append(remainingIDs[oldIdx])
                            let weight = receiverWeights[remainingIDs[oldIdx]] ?? 0.0
                            newRunningTotal = newRunningTotal + weight
                            newRemainingCumSum.append(newRunningTotal)
                        }
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
        
        access(all) view fun getStrategyName(): String {
            var name = "Fixed Prizes ("
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
        
        /// Strategy for selecting lottery winners and distributing prizes.
        /// Can be updated by admin with CriticalOps entitlement.
        access(contract) var winnerSelectionStrategy: {WinnerSelectionStrategy}
        
        /// Optional capability to winner tracker for leaderboard integration.
        /// If set, winners are recorded in the tracker after each draw.
        access(contract) var winnerTrackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>?
        
        /// Creates a new PoolConfig.
        /// @param assetType - Type of fungible token vault
        /// @param yieldConnector - DeFi connector for yield generation
        /// @param minimumDeposit - Minimum deposit amount (>= 0)
        /// @param drawIntervalSeconds - Seconds between draws (>= 1)
        /// @param distributionStrategy - Yield distribution strategy
        /// @param winnerSelectionStrategy - Winner selection strategy
        /// @param winnerTrackerCap - Optional winner tracker capability
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
        
        /// Updates the distribution strategy.
        /// @param strategy - New distribution strategy
        access(contract) fun setDistributionStrategy(strategy: {DistributionStrategy}) {
            self.distributionStrategy = strategy
        }
        
        /// Updates the winner selection strategy.
        /// @param strategy - New winner selection strategy
        access(contract) fun setWinnerSelectionStrategy(strategy: {WinnerSelectionStrategy}) {
            self.winnerSelectionStrategy = strategy
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
        
        /// Returns the winner selection strategy name for display.
        access(all) view fun getWinnerSelectionStrategyName(): String {
            return self.winnerSelectionStrategy.getStrategyName()
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
    /// 1. startDrawSnapshot() - Lock pool, capture cutoff time
    /// 2. captureStakesBatch() - Process N users per transaction (repeat)
    /// 3. finalizeDrawStart() - Request randomness after all users processed
    /// 
    /// During batch processing, deposits and withdrawals are locked to prevent
    /// manipulation between batches.
    /// 
    /// NOTE: This feature is not yet implemented - placeholder for future scaling.
    access(all) struct BatchDrawState {
        /// Timestamp when the draw was initiated (used for TWAB calculation).
        access(all) let drawCutoffTime: UFix64
        
        /// Epoch start time before startNewPeriod() was called.
        /// Needed to calculate TWAB for users in the previous epoch.
        access(all) let previousEpochStartTime: UFix64
        
        /// Accumulated weights from processed users (receiverID -> weight).
        access(all) var capturedWeights: {UInt64: UFix64}
        
        /// Running total of all captured weights.
        access(all) var totalWeight: UFix64
        
        /// Number of users processed so far.
        access(all) var processedCount: Int
        
        /// Epoch ID at time of snapshot (for validation).
        access(all) let snapshotEpochID: UInt64
        
        /// Creates a new BatchDrawState.
        /// @param cutoffTime - Draw timestamp for TWAB calculation
        /// @param epochStartTime - Start time of the epoch being drawn
        /// @param epochID - Current epoch ID
        init(cutoffTime: UFix64, epochStartTime: UFix64, epochID: UInt64) {
            self.drawCutoffTime = cutoffTime
            self.previousEpochStartTime = epochStartTime
            self.capturedWeights = {}
            self.totalWeight = 0.0
            self.processedCount = 0
            self.snapshotEpochID = epochID
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
    /// 4. processRewards() distributes yield per strategy
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
        
        /// Set of registered receiver IDs (for iteration during draws).
        access(self) let registeredReceivers: {UInt64: Bool}
        
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
        
        /// Cumulative treasury amount auto-forwarded to recipient.
        access(all) var totalTreasuryForwarded: UFix64
        
        /// Capability to treasury recipient for auto-forwarding.
        /// If nil, treasury is not auto-forwarded.
        access(self) var treasuryRecipientCap: Capability<&{FungibleToken.Receiver}>?
        
        // ============================================================
        // NESTED RESOURCES
        // ============================================================
        
        /// Manages savings: share accounting and TWAB tracking.
        access(self) let savingsDistributor: @SavingsDistributor
        
        /// Manages lottery: prize pool, NFTs, pending claims.
        access(self) let lotteryDistributor: @LotteryDistributor
        
        /// Holds pending draw receipt during two-phase draw process.
        /// Set during startDraw(), consumed during completeDraw().
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        
        /// On-chain randomness consumer for fair lottery selection.
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        /// Batch draw state for multi-transaction draws (not yet implemented).
        access(self) var batchDrawState: BatchDrawState?
        
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
            self.receiverBonusWeights = {}
            
            // Initialize accounting
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.lastDrawTimestamp = 0.0
            self.pendingLotteryYield = 0.0
            self.totalTreasuryForwarded = 0.0
            self.treasuryRecipientCap = nil
            
            // Create nested resources
            self.savingsDistributor <- create SavingsDistributor(vaultType: config.assetType)
            self.lotteryDistributor <- create LotteryDistributor(vaultType: config.assetType)
            
            // Initialize draw state
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            self.batchDrawState = nil
        }
        
        // ============================================================
        // RECEIVER REGISTRATION
        // ============================================================
        
        /// Registers a receiver ID with this pool.
        /// Called automatically when a user first deposits.
        /// @param receiverID - UUID of the PoolPositionCollection
        access(contract) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            self.registeredReceivers[receiverID] = true
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
                    
                    // Route dust to treasury if recipient configured
                    if dustAmount > 0.0 {
                        emit SavingsRoundingDustToTreasury(poolID: self.poolID, amount: dustAmount)
                        if let cap = self.treasuryRecipientCap {
                            if let recipientRef = cap.borrow() {
                                let dustVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: dustAmount)
                                if dustVault.balance > 0.0 {
                                    recipientRef.deposit(from: <- dustVault)
                                    self.totalTreasuryForwarded = self.totalTreasuryForwarded + dustAmount
                                    emit TreasuryForwarded(poolID: self.poolID, amount: dustAmount, recipient: cap.address)
                                } else {
                                    destroy dustVault
                                }
                            }
                        }
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
        /// 4. Update accounting (receiverDeposits, totalDeposited, totalStaked)
        /// 5. Deposit to yield source
        /// 
        /// TWAB is automatically updated in SavingsDistributor.deposit().
        /// 
        /// @param from - Vault containing funds to deposit (consumed)
        /// @param receiverID - UUID of the depositor's PoolPositionCollection
        access(contract) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive. Amount: ".concat(from.balance.toString())
                from.getType() == self.config.assetType: "Invalid vault type. Expected: ".concat(self.config.assetType.identifier).concat(", got: ").concat(from.getType().identifier)
                self.registeredReceivers[receiverID] != nil: "Receiver not registered. ReceiverID: ".concat(receiverID.toString())
            }
            
            // TODO: Future batch draw support - add check here:
            // assert(self.batchDrawState == nil, message: "Deposits locked during batch draw processing")
            
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
                self.processRewards()
            }
            
            let amount = from.balance
            
            // Record deposit in savings distributor (mints shares, updates TWAB)
            self.savingsDistributor.deposit(receiverID: receiverID, amount: amount)
            
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
        /// 6. Update accounting (receiverDeposits, totalDeposited, totalStaked)
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
            
            // TODO: Future batch draw support - add check here:
            // assert(self.batchDrawState == nil, message: "Withdrawals locked during batch draw processing")
            
            // Paused pool: nothing allowed
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed. ReceiverID: ".concat(receiverID.toString()).concat(", amount: ").concat(amount.toString()))
            
            // In emergency mode, check if we can auto-recover
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let _ = self.checkAndAutoRecover()
            }
            
            // Process pending yield before withdrawal (if in normal mode)
            if self.emergencyState == PoolEmergencyState.Normal && self.getAvailableYieldRewards() > 0.0 {
                self.processRewards()
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
            
            // Burn shares proportional to withdrawal
            let _ = self.savingsDistributor.withdraw(receiverID: receiverID, amount: actualWithdrawn)
            
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
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: actualWithdrawn)
            return <- withdrawn
        }
        
        // ============================================================
        // REWARD PROCESSING
        // ============================================================
        
        /// Processes available yield and distributes according to strategy.
        /// 
        /// FLOW:
        /// 1. Calculate available yield (yieldBalance - allocatedFunds)
        /// 2. Apply distribution strategy (savings/lottery/treasury split)
        /// 3. Accrue savings yield to share price
        /// 4. Add lottery yield to pendingLotteryYield (stays in yield source)
        /// 5. Forward treasury to configured recipient (if any)
        /// 
        /// Called automatically during deposits and withdrawals.
        /// Can also be called manually by admin.
        access(contract) fun processRewards() {
            // Calculate how much yield is available (above what's allocated)
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let allocatedFunds = self.totalStaked + self.pendingLotteryYield
            let availableYield: UFix64 = yieldBalance > allocatedFunds ? yieldBalance - allocatedFunds : 0.0
            
            // No yield to process
            if availableYield == 0.0 {
                return
            }
            
            // Apply distribution strategy
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: availableYield)
            
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
            
            // Process treasury portion + savings dust
            let totalTreasuryAmount = plan.treasuryAmount + savingsDust
            
            if totalTreasuryAmount > 0.0 {
                // Auto-forward to treasury recipient if configured
                if let cap = self.treasuryRecipientCap {
                    if let recipientRef = cap.borrow() {
                        let treasuryVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: totalTreasuryAmount)
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
                // If no recipient configured, treasury portion stays in yield source
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: availableYield,
                savingsAmount: plan.savingsAmount - savingsDust,
                lotteryAmount: plan.lotteryAmount
            )
        }
        
        // ============================================================
        // LOTTERY DRAW OPERATIONS
        // ============================================================
        
        /// Starts a lottery draw (Phase 1 of 2).
        /// 
        /// FLOW:
        /// 1. Validate state (Normal, no active draw, interval elapsed)
        /// 2. Capture all users' TWAB weights (time-weighted share-seconds)
        /// 3. Add bonus weights (scaled by epoch duration)
        /// 4. Start new epoch (resets TWAB for next draw)
        /// 5. Materialize pending lottery yield from yield source
        /// 6. Request randomness from Flow's RandomConsumer
        /// 7. Store PrizeDrawReceipt with weights and request
        /// 
        /// Must call completeDraw() after randomness is available (next block).
        /// 
        /// FAIRNESS: Uses share-seconds so:
        /// - More shares = more lottery weight
        /// - Longer deposits = more lottery weight
        /// - Share-based TWAB is stable against price fluctuations
        access(contract) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: \(self.emergencyState.rawValue)"
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            // Validate draw interval has elapsed
            assert(self.canDrawNow(), message: "Not enough blocks since last draw")
            
            // Final health check before draw
            if self.checkAndAutoTriggerEmergency() {
                panic("Emergency mode auto-triggered - cannot start draw")
            }
            
            // Capture all users' final TWAB for this epoch
            let timeWeightedStakes: {UInt64: UFix64} = {}
            for receiverID in self.registeredReceivers.keys {
                // Get accumulated share-seconds (captures current value)
                let twabStake = self.savingsDistributor.updateAndGetTimeWeightedShares(receiverID: receiverID)
                
                // Add bonus weights, scaled by epoch duration for fairness
                // (bonus per second × epoch duration = total bonus share-seconds)
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                let epochDuration = getCurrentBlock().timestamp - self.savingsDistributor.getEpochStartTime()
                let scaledBonus = bonusWeight * epochDuration
                
                let totalStake = twabStake + scaledBonus
                if totalStake > 0.0 {
                    timeWeightedStakes[receiverID] = totalStake
                }
            }
            
            // Start new epoch - all TWAB counters reset
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
                commitBlock: receipt.getRequestBlock() ?? 0
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
                (self.batchDrawState?.processedCount ?? 0) >= self.registeredReceivers.keys.length: "Batch processing not complete"
            }
            panic("Batch draw not yet implemented")
        }
        
        /// Completes a lottery draw (Phase 2 of 2).
        /// 
        /// FLOW:
        /// 1. Consume PrizeDrawReceipt (must have been created by startDraw)
        /// 2. Fulfill randomness request (secure on-chain random from previous block)
        /// 3. Apply winner selection strategy with captured weights
        /// 4. For each winner:
        ///    a. Withdraw prize from lottery pool
        ///    b. Auto-compound prize into winner's deposit (mints shares)
        ///    c. Re-deposit prize to yield source (continues earning)
        ///    d. Award any NFT prizes (stored for claiming)
        /// 5. Record winners in tracker (if configured)
        /// 6. Emit PrizesAwarded event
        /// 
        /// IMPORTANT: Prizes are AUTO-COMPOUNDED into deposits, not transferred.
        /// Winners can withdraw their increased balance at any time.
        access(contract) fun completeDraw() {
            pre {
                self.pendingDrawReceipt != nil: "No draw in progress"
            }
            
            // Extract and consume the pending receipt
            let receipt <- self.pendingDrawReceipt <- nil
            let unwrappedReceipt <- receipt!
            let totalPrizeAmount = unwrappedReceipt.prizeAmount
            
            // Get the weight snapshot captured at startDraw()
            let timeWeightedStakes = unwrappedReceipt.getTimeWeightedStakes()
            
            // Fulfill randomness request (must be different block from request)
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            
            // Apply winner selection strategy
            let selectionResult = self.config.winnerSelectionStrategy.selectWinners(
                randomNumber: randomNumber,
                receiverWeights: timeWeightedStakes,
                totalPrizeAmount: totalPrizeAmount
            )
            
            let winners = selectionResult.winners
            let prizeAmounts = selectionResult.amounts
            let nftIDsPerWinner = selectionResult.nftIDs
            
            // Handle case of no winners (e.g., no eligible participants)
            if winners.length == 0 {
                emit PrizesAwarded(
                    poolID: self.poolID,
                    winners: [],
                    amounts: [],
                    round: self.lotteryDistributor.getPrizeRound()
                )
                return
            }
            
            // Validate parallel arrays are consistent
            assert(winners.length == prizeAmounts.length, message: "Winners and prize amounts must match")
            assert(winners.length == nftIDsPerWinner.length, message: "Winners and NFT IDs must match")
            
            // Increment draw round
            let currentRound = self.lotteryDistributor.getPrizeRound() + 1
            self.lotteryDistributor.setPrizeRound(round: currentRound)
            var totalAwarded: UFix64 = 0.0
            
            // Process each winner
            for i in InclusiveRange(0, winners.length - 1) {
                let winnerID = winners[i]
                let prizeAmount = prizeAmounts[i]
                let nftIDsForWinner = nftIDsPerWinner[i]
                
                // Withdraw prize from lottery pool
                let prizeVault <- self.lotteryDistributor.withdrawPrize(
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                // AUTO-COMPOUND: Add prize to winner's deposit (mints shares)
                self.savingsDistributor.deposit(receiverID: winnerID, amount: prizeAmount)
                
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
                    for idx in InclusiveRange(0, winners.length - 1) {
                        trackerRef.recordWinner(
                            poolID: self.poolID,
                            round: currentRound,
                            winnerReceiverID: winners[idx],
                            amount: prizeAmounts[idx],
                            nftIDs: nftIDsPerWinner[idx]
                        )
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
        
        /// Returns the name of the current winner selection strategy.
        access(all) view fun getWinnerSelectionStrategyName(): String {
            return self.config.winnerSelectionStrategy.getStrategyName()
        }
        
        /// Updates the winner selection strategy. Called by Admin.
        /// @param strategy - New winner selection strategy
        access(contract) fun setWinnerSelectionStrategy(strategy: {WinnerSelectionStrategy}) {
            self.config.setWinnerSelectionStrategy(strategy: strategy)
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
        
        /// Returns whether the draw interval has elapsed and a draw can start.
        access(all) view fun canDrawNow(): Bool {
            return (getCurrentBlock().timestamp - self.lastDrawTimestamp) >= self.config.drawIntervalSeconds
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
        
        access(all) view fun getUserTimeWeightedShares(receiverID: UInt64): UFix64 {
            return self.savingsDistributor.getTimeWeightedShares(receiverID: receiverID)
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
        
        access(all) view fun getUserProjectedShareSeconds(receiverID: UInt64, atTime: UFix64): UFix64 {
            return self.savingsDistributor.calculateShareSecondsAtTime(receiverID: receiverID, targetTime: atTime)
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
            if let cap = self.treasuryRecipientCap {
                return cap.check()
            }
            return false
        }
        
        access(all) view fun getTotalTreasuryForwarded(): UFix64 {
            return self.totalTreasuryForwarded
        }
        
        /// Set treasury recipient for auto-forwarding. Only callable by account owner.
        access(contract) fun setTreasuryRecipient(cap: Capability<&{FungibleToken.Receiver}>?) {
            self.treasuryRecipientCap = cap
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
        
        /// Internal: Returns the user's current accumulated entries (TWAB / drawInterval).
        /// This represents their lottery weight accumulated so far, NOT their final weight.
        access(self) view fun getCurrentEntries(receiverID: UInt64): UFix64 {
            let twab = self.savingsDistributor.getTimeWeightedShares(receiverID: receiverID)
            let drawInterval = self.config.drawIntervalSeconds
            if drawInterval == 0.0 {
                return 0.0
            }
            return twab / drawInterval
        }
        
        /// Returns the user's entry count for this draw.
        /// Projects TWAB forward to draw time assuming no share changes.
        /// Formula: (currentTWAB + shares × remainingTime) / drawInterval
        /// 
        /// Examples:
        /// - 10 shares at start of draw → 10 entries
        /// - 10 shares deposited halfway through draw → 5 entries
        /// - At next round, same 10 shares → 10 entries (full credit)
        access(all) view fun getUserEntries(receiverID: UInt64): UFix64 {
            let drawInterval = self.config.drawIntervalSeconds
            if drawInterval == 0.0 {
                return 0.0
            }
            
            let currentTwab = self.savingsDistributor.getTimeWeightedShares(receiverID: receiverID)
            let currentShares = self.savingsDistributor.getUserShares(receiverID: receiverID)
            let remainingTime = self.getTimeUntilNextDraw()
            
            // Project TWAB forward: current + (shares × remaining time)
            let projectedTwab = currentTwab + (currentShares * remainingTime)
            return projectedTwab / drawInterval
        }
        
        /// Returns how far through the current draw period we are (0.0 to 1.0+).
        /// - 0.0 = draw just started
        /// - 0.5 = halfway through draw period
        /// - 1.0 = draw period complete, ready for next draw
        access(all) view fun getDrawProgressPercent(): UFix64 {
            let epochStart = self.savingsDistributor.getEpochStartTime()
            let elapsed = getCurrentBlock().timestamp - epochStart
            let drawInterval = self.config.drawIntervalSeconds
            if drawInterval == 0.0 {
                return 0.0
            }
            return elapsed / drawInterval
        }
        
        /// Returns time remaining until next draw is available (in seconds).
        /// Returns 0.0 if draw can happen now.
        access(all) view fun getTimeUntilNextDraw(): UFix64 {
            let epochStart = self.savingsDistributor.getEpochStartTime()
            let elapsed = getCurrentBlock().timestamp - epochStart
            let drawInterval = self.config.drawIntervalSeconds
            if elapsed >= drawInterval {
                return 0.0
            }
            return drawInterval - elapsed
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