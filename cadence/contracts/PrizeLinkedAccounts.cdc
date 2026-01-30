/*
PrizeLinkedAccounts - Prize-Linked Accounts Protocol

Deposit tokens into a pool to earn rewards and prizes.  Aggregated deposits are deposited into a yield generating
source and the yield is distributed to the depositors based on a configurable distribution strategy.

Architecture:
- ERC4626-style shares with virtual offset protection (inflation attack resistant)
- TWAB (time-weighted average balance) using normalized weights for fair prize weighting
- On-chain randomness via Flow's RandomConsumer
- Modular yield sources via DeFi Actions interface
- Configurable distribution strategies (rewards/prize/protocolFee split)
- Pluggable winner selection (weighted single, multi-winner, fixed tiers)
- Resource-based position ownership via PoolPositionCollection
- Emergency mode with auto-recovery and health monitoring
- NFT prize support with pending claims
- Direct funding for external sponsors
- Bonus prize weights for promotions
- Winner tracking integration for leaderboards

Prize Fairness:
- Uses normalized TWAB (average shares over time) for prize weighting
- Share-based TWAB is stable against price fluctuations (yield/loss)
- Rewards commitment: longer deposits = higher time-weighted average
- Early depositors get more shares per dollar, increasing prize weight
- Supports unlimited TVL and any round duration within UFix64 limits

Core Components:
- ShareTracker: Manages share-based accounting
- PrizeDistributor: Prize pool, NFT prizes, and draw execution
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

access(all) contract PrizeLinkedAccounts {    
    /// Entitlement for configuration operations (non-destructive admin actions).
    /// Examples: updating draw intervals, processing rewards, managing bonus weights.
    access(all) entitlement ConfigOps
    
    /// Entitlement for critical operations (potentially destructive admin actions).
    /// Examples: creating pools, enabling emergency mode, starting/completing draws.
    access(all) entitlement CriticalOps
    
    /// Entitlement reserved exclusively for account owner operations.
    /// SECURITY: Never issue capabilities with this entitlement - it protects
    /// protocol fee recipient configuration which could redirect funds if compromised.
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
    
    /// Minimum yield amount required to trigger distribution.
    /// Amounts below this threshold remain in the yield source and accumulate
    /// until the next sync when they may exceed the threshold.
    /// 
    /// Set to 100x minimum UFix64 (0.000001) to ensure:
    /// - All percentage buckets receive non-zero allocations (even 1% buckets)
    /// - No precision loss from UFix64 rounding during distribution
    /// - Negligible economic impact (~$0.000002 at $2/FLOW)
    access(all) let MINIMUM_DISTRIBUTION_THRESHOLD: UFix64

    /// Maximum value for UFix64 type (≈ 184.467 billion).
    /// Used for percentage calculations in weight warnings.
    access(all) let UFIX64_MAX: UFix64
    
    /// Warning threshold for normalized weight values (90% of UFix64 max).
    /// If totalWeight exceeds this during batch processing, emit a warning event.
    /// With normalized TWAB this should never be reached in practice, but provides safety.
    access(all) let WEIGHT_WARNING_THRESHOLD: UFix64

    /// Maximum total value locked (TVL) per pool (80% of UFix64 max ≈ 147 billion).
    /// Deposits that would exceed this limit are rejected to prevent UFix64 overflow.
    /// This provides a safety margin for yield accrual and weight calculations.
    access(all) let SAFE_MAX_TVL: UFix64

    // ============================================================
    // STORAGE PATHS
    // ============================================================
    
    /// Storage path where users store their PoolPositionCollection resource.
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    
    /// Public path for PoolPositionCollection capability (read-only access).
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    /// Storage path where users store their SponsorPositionCollection resource.
    /// Sponsors earn rewards yield but are NOT eligible to win prizes.
    access(all) let SponsorPositionCollectionStoragePath: StoragePath
    
    /// Public path for SponsorPositionCollection capability (read-only access).
    access(all) let SponsorPositionCollectionPublicPath: PublicPath

    /// Storage path for the Admin resource.
    access(all) let AdminStoragePath: StoragePath
    
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
    /// @param shares - Number of shares minted
    /// @param ownerAddress - Current owner address of the PoolPositionCollection (nil if resource transferred/not stored)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64, shares: UFix64, ownerAddress: Address?)
    
    /// Emitted when a sponsor deposits funds (prize-ineligible).
    /// Sponsors earn rewards yield but cannot win prizes.
    /// @param poolID - Pool receiving the deposit
    /// @param receiverID - UUID of the sponsor's SponsorPositionCollection
    /// @param amount - Amount deposited
    /// @param shares - Number of shares minted
    /// @param ownerAddress - Current owner address of the SponsorPositionCollection (nil if resource transferred/not stored)
    access(all) event SponsorDeposited(poolID: UInt64, receiverID: UInt64, amount: UFix64, shares: UFix64, ownerAddress: Address?)
    
    /// Emitted when a user withdraws funds from a pool.
    /// @param poolID - Pool being withdrawn from
    /// @param receiverID - UUID of the user's PoolPositionCollection
    /// @param requestedAmount - Amount the user requested to withdraw
    /// @param actualAmount - Amount actually withdrawn (may be less if yield source has insufficient liquidity)
    /// @param ownerAddress - Current owner address of the PoolPositionCollection (nil if resource transferred/not stored)
    access(all) event Withdrawn(poolID: UInt64, receiverID: UInt64, requestedAmount: UFix64, actualAmount: UFix64, ownerAddress: Address?)
    
    // ============================================================
    // EVENTS - Reward Processing
    // ============================================================
    
    /// Emitted when yield rewards are processed and distributed.
    /// @param poolID - Pool processing rewards
    /// @param totalAmount - Total yield amount processed
    /// @param rewardsAmount - Portion allocated to rewards (auto-compounds)
    /// @param prizeAmount - Portion allocated to prize pool
    access(all) event RewardsProcessed(poolID: UInt64, totalAmount: UFix64, rewardsAmount: UFix64, prizeAmount: UFix64)
    
    /// Emitted when rewards yield is accrued to the share price.
    /// @param poolID - Pool accruing yield
    /// @param amount - Amount of yield accrued (increases share price for all depositors)
    access(all) event RewardsYieldAccrued(poolID: UInt64, amount: UFix64)
    
    /// Emitted when a deficit is applied across allocations.
    /// @param poolID - Pool experiencing the deficit
    /// @param totalDeficit - Total deficit amount detected
    /// @param absorbedByProtocolFee - Amount absorbed by pending protocol fee
    /// @param absorbedByPrize - Amount absorbed by pending prize yield
    /// @param absorbedByRewards - Amount absorbed by rewards (decreases share price)
    access(all) event DeficitApplied(poolID: UInt64, totalDeficit: UFix64, absorbedByProtocolFee: UFix64, absorbedByPrize: UFix64, absorbedByRewards: UFix64)

    /// Emitted when a deficit cannot be fully reconciled (pool insolvency).
    /// This means protocol fee, prize, and rewards were all exhausted but deficit remains.
    /// @param poolID - Pool experiencing insolvency
    /// @param unreconciledAmount - Deficit amount that could not be absorbed
    access(all) event InsolvencyDetected(poolID: UInt64, unreconciledAmount: UFix64)
    
    /// Emitted when rounding dust from rewards distribution is sent to protocol fee.
    /// This occurs due to virtual shares absorbing a tiny fraction of yield.
    /// @param poolID - Pool generating dust
    /// @param amount - Dust amount routed to protocol fee
    access(all) event RewardsRoundingDustToProtocolFee(poolID: UInt64, amount: UFix64)
    
    // ============================================================
    // EVENTS - Prize/Draw
    // ============================================================
    
    /// Emitted when prizes are awarded to winners.
    /// @param poolID - Pool awarding prizes
    /// @param winners - Array of winner receiverIDs
    /// @param winnerAddresses - Array of winner addresses (nil = resource transferred/destroyed, parallel to winners)
    /// @param amounts - Array of prize amounts (parallel to winners)
    /// @param round - Draw round number
    access(all) event PrizesAwarded(poolID: UInt64, winners: [UInt64], winnerAddresses: [Address?], amounts: [UFix64], round: UInt64)
    
    /// Emitted when the prize pool receives funding.
    /// @param poolID - Pool receiving funds
    /// @param amount - Amount added to prize pool
    /// @param source - Source of funding (e.g., "yield_pending", "direct")
    access(all) event PrizePoolFunded(poolID: UInt64, amount: UFix64, source: String)
    
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
    /// @param totalWeight - Total prize weight captured
    /// @param prizeAmount - Prize pool amount
    /// @param commitBlock - Block where randomness was committed
    access(all) event DrawRandomnessRequested(poolID: UInt64, totalWeight: UFix64, prizeAmount: UFix64, commitBlock: UInt64)

    /// Emitted when the pool enters intermission (after completeDraw, before startNextRound).
    /// Intermission is a normal state where deposits/withdrawals continue but no draw can occur.
    /// @param poolID - ID of the pool
    /// @param completedRoundID - ID of the round that just completed
    /// @param prizePoolBalance - Current balance in the prize pool
    access(all) event IntermissionStarted(poolID: UInt64, completedRoundID: UInt64, prizePoolBalance: UFix64)

    /// Emitted when the pool exits intermission and a new round begins.
    /// @param poolID - ID of the pool
    /// @param newRoundID - ID of the newly started round
    /// @param roundDuration - Duration of the new round in seconds
    access(all) event IntermissionEnded(poolID: UInt64, newRoundID: UInt64, roundDuration: UFix64)

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
    
    /// Emitted when the draw interval for FUTURE rounds is changed.
    /// This affects rounds created after the next startDraw().
    /// Does NOT affect the current round's timing or eligibility.
    /// @param poolID - ID of the pool being configured
    /// @param oldInterval - Previous draw interval in seconds
    /// @param newInterval - New draw interval in seconds
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event FutureRoundsIntervalUpdated(poolID: UInt64, oldInterval: UFix64, newInterval: UFix64, adminUUID: UInt64)

    /// Emitted when the current round's target end time is updated.
    /// Admin can extend or shorten the current round by adjusting target end time.
    /// Can only be changed before startDraw() is called on the round.
    /// @param poolID - ID of the pool being configured
    /// @param roundID - ID of the round being modified
    /// @param oldTarget - Previous target end time
    /// @param newTarget - New target end time
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event RoundTargetEndTimeUpdated(poolID: UInt64, roundID: UInt64, oldTarget: UFix64, newTarget: UFix64, adminUUID: UInt64)

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
    
    /// Emitted when admin performs storage cleanup on a pool.
    /// @param poolID - ID of the pool being cleaned
    /// @param ghostReceiversCleaned - Number of 0-share receivers unregistered
    /// @param userSharesCleaned - Number of 0-value userShares entries removed
    /// @param pendingNFTClaimsCleaned - Number of empty pendingNFTClaims arrays removed
    /// @param adminUUID - UUID of the Admin resource performing cleanup (audit trail)
    access(all) event PoolStorageCleanedUp(
        poolID: UInt64,
        ghostReceiversCleaned: Int,
        userSharesCleaned: Int,
        pendingNFTClaimsCleaned: Int,
        nextIndex: Int,
        totalReceivers: Int,
        adminUUID: UInt64
    )
    
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
    
    /// Emitted when the protocol fee receives funding
    /// @param poolID - Pool whose protocol fee received funds
    /// @param amount - Amount of tokens funded
    /// @param source - Source of funding (e.g., "rounding_dust", "fees")
    access(all) event ProtocolFeeFunded(poolID: UInt64, amount: UFix64, source: String)
    
    /// Emitted when the protocol fee recipient address is changed.
    /// SECURITY: This is a sensitive operation - recipient receives protocol fees.
    /// @param poolID - Pool being configured
    /// @param newRecipient - New protocol fee recipient address (nil to disable forwarding)
    /// @param adminUUID - UUID of the Admin resource performing the update (audit trail)
    access(all) event ProtocolFeeRecipientUpdated(poolID: UInt64, newRecipient: Address?, adminUUID: UInt64)
    
    /// Emitted when protocol fee is auto-forwarded to the configured recipient.
    /// @param poolID - Pool forwarding protocol fee
    /// @param amount - Amount forwarded
    /// @param recipient - Address receiving the funds
    access(all) event ProtocolFeeForwarded(poolID: UInt64, amount: UFix64, recipient: Address)
    
    // ============================================================
    // EVENTS - Bonus Weight Management
    // ============================================================
    
    /// Emitted when a user's bonus prize weight is set (replaces existing).
    /// Bonus weights increase prize odds for promotional purposes.
    /// @param poolID - Pool where bonus is being set
    /// @param receiverID - UUID of the user's PoolPositionCollection receiving the bonus
    /// @param bonusWeight - New bonus weight value (replaces any existing bonus)
    /// @param reason - Human-readable explanation for the bonus (e.g., "referral", "promotion")
    /// @param adminUUID - UUID of the Admin resource setting the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was set
    access(all) event BonusPrizeWeightSet(poolID: UInt64, receiverID: UInt64, bonusWeight: UFix64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when additional bonus weight is added to a user's existing bonus.
    /// @param poolID - Pool where bonus is being added
    /// @param receiverID - UUID of the user's PoolPositionCollection receiving additional bonus
    /// @param additionalWeight - Amount of weight being added
    /// @param newTotalBonus - User's new total bonus weight after addition
    /// @param reason - Human-readable explanation for the bonus addition
    /// @param adminUUID - UUID of the Admin resource adding the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was added
    access(all) event BonusPrizeWeightAdded(poolID: UInt64, receiverID: UInt64, additionalWeight: UFix64, newTotalBonus: UFix64, reason: String, adminUUID: UInt64, timestamp: UFix64)
    
    /// Emitted when a user's bonus prize weight is completely removed.
    /// @param poolID - Pool where bonus is being removed
    /// @param receiverID - UUID of the user's PoolPositionCollection losing the bonus
    /// @param previousBonus - Bonus weight that was removed
    /// @param adminUUID - UUID of the Admin resource removing the bonus (audit trail)
    /// @param timestamp - Block timestamp when the bonus was removed
    access(all) event BonusPrizeWeightRemoved(poolID: UInt64, receiverID: UInt64, previousBonus: UFix64, adminUUID: UInt64, timestamp: UFix64)
    
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
    /// @param reason - Explanation for why NFT is pending (e.g., "prize_win")
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
    // EVENTS - Health & Monitoring
    // ============================================================
    
    /// Emitted when totalWeight during batch processing exceeds the warning threshold.
    /// This is a proactive alert that the system is approaching capacity limits.
    /// Provides early warning for operational monitoring.
    /// @param poolID - Pool with high weight
    /// @param totalWeight - Current total weight value
    /// @param warningThreshold - Threshold that was exceeded
    /// @param percentOfMax - Approximate percentage of UFix64 max
    access(all) event WeightWarningThresholdExceeded(poolID: UInt64, totalWeight: UFix64, warningThreshold: UFix64, percentOfMax: UFix64)
    
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
    /// @param destination - Numeric destination code: 0=Rewards, 1=Prize (see PoolFundingDestination enum)
    /// @param destinationName - Human-readable destination name (e.g., "Rewards", "Prize")
    /// @param amount - Amount of tokens being funded
    /// @param adminUUID - UUID of the Admin resource performing the funding (audit trail)
    /// @param purpose - Human-readable explanation for the funding (e.g., "weekly_sponsorship")
    /// @param metadata - Additional key-value metadata for the funding event
    access(all) event DirectFundingReceived(poolID: UInt64, destination: UInt8, destinationName: String, amount: UFix64, adminUUID: UInt64, purpose: String, metadata: {String: String})
    
    // ============================================================
    // CONTRACT STATE
    // ============================================================
    
    /// Mapping of pool IDs to Pool resources.
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
        /// Fund the share tracker (increases share price for all users)
        access(all) case Rewards
        /// Fund the prize pool (available for next draw)
        access(all) case Prize
    }
    
    // ============================================================
    // STRUCTS
    // ============================================================
    
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
        
        /// Minimum ratio of yield source balance to allocatedRewards (0.8-1.0).
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
                minYieldSourceHealth >= 0.0 && minYieldSourceHealth <= 1.0: "minYieldSourceHealth must be between 0.0 and 1.0 but got \(minYieldSourceHealth)"
                maxWithdrawFailures > 0: "maxWithdrawFailures must be at least 1 but got \(maxWithdrawFailures)"
                minBalanceThreshold >= 0.8 && minBalanceThreshold <= 1.0: "minBalanceThreshold must be between 0.8 and 1.0 but got \(minBalanceThreshold)"
                (minRecoveryHealth ?? 0.5) >= 0.0 && (minRecoveryHealth ?? 0.5) <= 1.0: "minRecoveryHealth must be between 0.0 and 1.0 but got \(minRecoveryHealth ?? 0.5)"
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
    /// - OwnerOnly: Highly sensitive operations (protocol fee recipient - NEVER issue capabilities)
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
        
        /// Updates the prize distribution for prize draws.
        /// @param poolID - ID of the pool to update
        /// @param newDistribution - The new prize distribution (e.g., single winner, percentage split)
        access(CriticalOps) fun updatePoolPrizeDistribution(
            poolID: UInt64,
            newDistribution: {PrizeDistribution}
        ) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
        
        /// Updates the draw interval for FUTURE rounds only.
        /// 
        /// This function ONLY affects future rounds created after the next startDraw().
        /// The current active round is NOT affected (neither eligibility nor draw timing).
        /// 
        /// Use this when you want to change the interval starting from the NEXT round
        /// without affecting the current round at all.
        /// 
        /// @param poolID - ID of the pool to update
        /// @param newInterval - New draw interval in seconds (must be >= 1.0)
        access(ConfigOps) fun updatePoolDrawIntervalForFutureRounds(
            poolID: UInt64,
            newInterval: UFix64
        ) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)

            let oldInterval = poolRef.getConfig().drawIntervalSeconds
            poolRef.setDrawIntervalSecondsForFutureOnly(interval: newInterval)

            emit FutureRoundsIntervalUpdated(
                poolID: poolID,
                oldInterval: oldInterval,
                newInterval: newInterval,
                adminUUID: self.uuid
            )
        }

        /// Updates the current round's target end time.
        ///
        /// Use this to extend or shorten the current round. Can only be called
        /// before startDraw() is called on this round.
        ///
        /// This does NOT retroactively change existing users' TWAB. The TWAB math
        /// uses fixed-scale accumulation and normalizes by actual elapsed time
        /// at finalization, so extending/shortening the round is fair to all users.
        ///
        /// @param poolID - ID of the pool to update
        /// @param newTargetEndTime - New target end time (must be after round start time)
        access(ConfigOps) fun updateCurrentRoundTargetEndTime(
            poolID: UInt64,
            newTargetEndTime: UFix64
        ) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)

            let oldTarget = poolRef.getCurrentRoundTargetEndTime()
            let roundID = poolRef.getActiveRoundID()

            poolRef.setCurrentRoundTargetEndTime(newTarget: newTargetEndTime)

            emit RoundTargetEndTimeUpdated(
                poolID: poolID,
                roundID: roundID,
                oldTarget: oldTarget,
                newTarget: newTargetEndTime,
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
        /// Use when yield source is compromised or protocol-level issues detected.
        /// @param poolID - ID of the pool to put in emergency mode
        /// @param reason - Human-readable reason for emergency (logged in event)
        access(CriticalOps) fun enableEmergencyMode(poolID: UInt64, reason: String) {
            pre {
                reason.length > 0: "Reason cannot be empty. Pool ID: \(poolID)"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.setEmergencyMode(reason: reason)
            emit PoolEmergencyEnabled(poolID: poolID, reason: reason, adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Disables emergency mode and returns pool to normal operation.
        /// Clears consecutive failure counter and enables all operations.
        /// @param poolID - ID of the pool to restore
        access(CriticalOps) fun disableEmergencyMode(poolID: UInt64) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
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
                reason.length > 0: "Reason cannot be empty. Pool ID: \(poolID)"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.setPartialMode(reason: reason)
            emit PoolPartialModeEnabled(poolID: poolID, reason: reason, adminUUID: self.uuid, timestamp: getCurrentBlock().timestamp)
        }
        
        /// Updates the emergency configuration for a pool.
        /// Controls auto-triggering thresholds and recovery behavior.
        /// @param poolID - ID of the pool to configure
        /// @param newConfig - New emergency configuration
        access(CriticalOps) fun updateEmergencyConfig(poolID: UInt64, newConfig: EmergencyConfig) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.setEmergencyConfig(config: newConfig)
            emit EmergencyConfigUpdated(poolID: poolID, adminUUID: self.uuid)
        }
        
        /// Directly funds a pool component with external tokens.
        /// Use for sponsorships, promotional prize pools, or yield subsidies.
        /// @param poolID - ID of the pool to fund
        /// @param destination - Where to route funds (Rewards or Prize)
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
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
                case PoolFundingDestination.Rewards: return "Rewards"
                case PoolFundingDestination.Prize: return "Prize"
                default: return "Unknown"
            }
        }
        
        /// Creates a new prize-linked accounts pool.
        /// @param config - Pool configuration (asset type, yield connector, strategies, etc.)
        /// @param emergencyConfig - Optional emergency configuration (uses defaults if nil)
        /// @return The ID of the newly created pool
        access(CriticalOps) fun createPool(
            config: PoolConfig,
            emergencyConfig: EmergencyConfig?
        ): UInt64 {
            // Use provided config or fall back to sensible defaults
            let finalEmergencyConfig = emergencyConfig 
                ?? PrizeLinkedAccounts.createDefaultEmergencyConfig()
            
            let poolID = PrizeLinkedAccounts.createPool(
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            poolRef.syncWithYieldSource()
        }
        
        /// Directly sets the pool's operational state.
        /// Provides unified interface for all state transitions.
        /// @param poolID - ID of the pool
        /// @param state - Target state (Normal, Paused, EmergencyMode, PartialMode)
        /// @param reason - Optional reason for non-Normal states
        access(CriticalOps) fun setPoolState(poolID: UInt64, state: PoolEmergencyState, reason: String?) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
        
        /// Set the protocol fee recipient for automatic forwarding.
        /// Once set, protocol fee is auto-forwarded when round ends.
        /// Pass nil to disable auto-forwarding (funds stored in unclaimedProtocolFeeVault).
        ///
        /// IMPORTANT: The recipient MUST accept the same vault type as the pool's asset.
        /// For example, if the pool uses FLOW tokens, the recipient must be a FLOW receiver.
        /// A type mismatch will cause startDraw() to fail. If this happens,
        /// clear the recipient (set to nil) and retry the draw - funds will go to
        /// unclaimedProtocolFeeVault for manual withdrawal.
        ///
        /// SECURITY: Requires OwnerOnly entitlement - NEVER issue capabilities with this.
        /// Only the account owner (via direct storage borrow with auth) can call this.
        /// For multi-sig protection, store Admin in a multi-sig account.
        ///
        /// @param poolID - ID of the pool to configure
        /// @param recipientCap - Capability to receive protocol fee, or nil to disable
        access(OwnerOnly) fun setPoolProtocolFeeRecipient(
            poolID: UInt64,
            recipientCap: Capability<&{FungibleToken.Receiver}>?
        ) {
            pre {
                // Validate capability is usable if provided
                recipientCap?.check() ?? true: "Protocol fee recipient capability is invalid or cannot be borrowed. Pool ID: \(poolID), Recipient address: \(recipientCap?.address?.toString() ?? "nil")"
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            poolRef.setProtocolFeeRecipient(cap: recipientCap)
            
            emit ProtocolFeeRecipientUpdated(
                poolID: poolID,
                newRecipient: recipientCap?.address,
                adminUUID: self.uuid
            )
        }
        
        /// Sets or replaces a user's bonus prize weight.
        /// Bonus weight is added to their TWAB-based weight during draw selection.
        /// Use for promotional campaigns or loyalty rewards.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        /// @param bonusWeight - Weight to assign (replaces any existing bonus)
        /// @param reason - Human-readable reason for the bonus (audit trail)
        access(ConfigOps) fun setBonusPrizeWeight(
            poolID: UInt64,
            receiverID: UInt64,
            bonusWeight: UFix64,
            reason: String
        ) {
            pre {
                reason.length > 0: "Reason cannot be empty. Pool ID: \(poolID), Receiver ID: \(receiverID)"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            poolRef.setBonusWeight(receiverID: receiverID, bonusWeight: bonusWeight, reason: reason, adminUUID: self.uuid)
        }
        
        /// Adds additional bonus weight to a user's existing bonus.
        /// Cumulative with any previous bonus weight assigned.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        /// @param additionalWeight - Weight to add (must be > 0)
        /// @param reason - Human-readable reason for the addition
        access(ConfigOps) fun addBonusPrizeWeight(
            poolID: UInt64,
            receiverID: UInt64,
            additionalWeight: UFix64,
            reason: String
        ) {
            pre {
                additionalWeight > 0.0: "Additional weight must be positive (greater than 0). Pool ID: \(poolID), Receiver ID: \(receiverID), Received weight: \(additionalWeight)"
                reason.length > 0: "Reason cannot be empty. Pool ID: \(poolID), Receiver ID: \(receiverID)"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            poolRef.addBonusWeight(receiverID: receiverID, additionalWeight: additionalWeight, reason: reason, adminUUID: self.uuid)
        }
        
        /// Removes all bonus prize weight from a user.
        /// User returns to pure TWAB-based prize odds.
        /// @param poolID - ID of the pool
        /// @param receiverID - UUID of the user's PoolPositionCollection
        access(ConfigOps) fun removeBonusPrizeWeight(
            poolID: UInt64,
            receiverID: UInt64
        ) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            poolRef.removeBonusWeight(receiverID: receiverID, adminUUID: self.uuid)
        }
        
        /// Deposits an NFT to be awarded as a prize in future draws.
        /// NFTs are stored in the prize distributor and assigned via winner selection strategy.
        /// @param poolID - ID of the pool to receive the NFT
        /// @param nft - The NFT resource to deposit
        access(ConfigOps) fun depositNFTPrize(
            poolID: UInt64,
            nft: @{NonFungibleToken.NFT}
        ) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
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
        // Flow: startPoolDraw() → processPoolDrawBatch() (repeat) → completePoolDraw()
        // Note: Randomness is requested during startPoolDraw() and fulfilled during completePoolDraw().

        /// Starts a prize draw for a pool (Phase 1 of 3).
        /// 
        /// This instantly transitions rounds and initializes batch processing.
        /// Users can continue depositing/withdrawing immediately.
        /// 
        /// @param poolID - ID of the pool to start draw for
        access(CriticalOps) fun startPoolDraw(poolID: UInt64) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.startDraw()
        }
        
        /// Processes a batch of receivers for weight capture (Phase 2 of 3).
        /// 
        /// Call repeatedly until return value is 0 (or isDrawBatchComplete()).
        /// Each call processes up to `limit` receivers.
        /// 
        /// @param poolID - ID of the pool
        /// @param limit - Maximum receivers to process this batch
        /// @return Number of receivers remaining to process
        access(CriticalOps) fun processPoolDrawBatch(poolID: UInt64, limit: Int): Int {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            return poolRef.processDrawBatch(limit: limit)
        }
        
        /// Completes a prize draw for a pool (Phase 3 of 3).
        /// 
        /// Fulfills randomness request, selects winners, and distributes prizes.
        /// Prizes are auto-compounded into winners' deposits.
        /// 
        /// PREREQUISITES:
        /// - startPoolDraw() must have been called
        /// - processPoolDrawBatch() must have been called until complete
        /// - At least 1 block must have passed since startPoolDraw()
        /// 
        /// @param poolID - ID of the pool to complete draw for
        access(CriticalOps) fun completePoolDraw(poolID: UInt64) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.completeDraw()
        }
        
        /// Starts the next round for a pool, exiting intermission (Phase 5 - optional).
        /// 
        /// After completeDraw(), the pool enters intermission. Call this to begin
        /// the next round with fresh TWAB tracking.
        /// 
        /// @param poolID - ID of the pool to start next round for
        access(ConfigOps) fun startNextRound(poolID: UInt64) {
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            poolRef.startNextRound()
        }

        /// Withdraws unclaimed protocol fee from a pool.
        /// 
        /// Protocol fee accumulates in the unclaimed vault when no protocol fee recipient
        /// is configured at draw time. This function allows admin to withdraw those funds.
        /// 
        /// @param poolID - ID of the pool to withdraw from
        /// @param amount - Amount to withdraw (will be capped at available balance)
        /// @param recipient - Capability to receive the withdrawn funds
        /// @return Actual amount withdrawn (may be less than requested if insufficient balance)
        access(CriticalOps) fun withdrawUnclaimedProtocolFee(
            poolID: UInt64,
            amount: UFix64,
            recipient: Capability<&{FungibleToken.Receiver}>
        ): UFix64 {
            pre {
                recipient.check(): "Recipient capability is invalid"
                amount > 0.0: "Amount must be greater than 0"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            let withdrawn <- poolRef.withdrawUnclaimedProtocolFee(amount: amount)
            let actualAmount = withdrawn.balance
            
            if actualAmount > 0.0 {
                recipient.borrow()!.deposit(from: <- withdrawn)
                emit ProtocolFeeForwarded(
                    poolID: poolID,
                    amount: actualAmount,
                    recipient: recipient.address
                )
            } else {
                destroy withdrawn
            }
            
            return actualAmount
        }

        /// Cleans up stale dictionary entries and ghost receivers to manage storage growth.
        /// 
        /// This function should be called periodically (e.g., after each draw or weekly) to:
        /// 1. Remove "ghost" receivers (0-share users still in registeredReceiverList)
        /// 2. Clean up userShares entries with 0.0 value
        /// 3. Remove empty pendingNFTClaims arrays
        /// 
        /// Uses cursor-based batching to avoid gas limits - call multiple times with
        /// increasing startIndex until nextIndex >= totalReceivers in the result.
        /// 
        /// @param poolID - ID of the pool to clean up
        /// @param startIndex - Index in registeredReceiverList to start iterating from (0 for first call)
        /// @param limit - Max receivers to process per call (for gas management)
        /// @return CleanupResult with counts and nextIndex for continuation
        access(ConfigOps) fun cleanupPoolStaleEntries(
            poolID: UInt64,
            startIndex: Int,
            limit: Int
        ): {String: Int} {
            pre {
                startIndex >= 0: "Start index must be non-negative"
                limit > 0: "Limit must be positive"
            }
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            let result = poolRef.cleanupStaleEntries(startIndex: startIndex, limit: limit)
            
            emit PoolStorageCleanedUp(
                poolID: poolID,
                ghostReceiversCleaned: result["ghostReceivers"] ?? 0,
                userSharesCleaned: result["userShares"] ?? 0,
                pendingNFTClaimsCleaned: result["pendingNFTClaims"] ?? 0,
                nextIndex: result["nextIndex"] ?? 0,
                totalReceivers: result["totalReceivers"] ?? 0,
                adminUUID: self.uuid
            )
            
            return result
        }

    }
    
    
    // ============================================================
    // DISTRIBUTION STRATEGY - Yield Allocation
    // ============================================================
    
    /// Represents the result of a yield distribution calculation.
    /// Contains the amounts to allocate to each component.
    access(all) struct DistributionPlan {
        /// Amount allocated to rewards (increases share price for all depositors)
        access(all) let rewardsAmount: UFix64
        /// Amount allocated to prize pool (awarded to winners)
        access(all) let prizeAmount: UFix64
        /// Amount allocated to protocol fee (protocol fees)
        access(all) let protocolFeeAmount: UFix64
        
        /// Creates a new DistributionPlan.
        /// @param rewards - Amount for rewards distribution
        /// @param prize - Amount for prize pool
        /// @param protocolFee - Amount for protocol
        init(rewards: UFix64, prize: UFix64, protocolFee: UFix64) {
            self.rewardsAmount = rewards
            self.prizeAmount = prize
            self.protocolFeeAmount = protocolFee
        }
    }
    
    /// Strategy Pattern interface for yield distribution algorithms.
    /// 
    /// Implementations determine how yield is split between rewards, prize, and protocol fee.
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
    /// Example: FixedPercentageStrategy(rewards: 0.4, prize: 0.4, protocolFee: 0.2)
    /// - 40% of yield goes to rewards (increases share price)
    /// - 40% goes to prize pool
    /// - 20% goes to protocol fee
    access(all) struct FixedPercentageStrategy: DistributionStrategy {
        /// Percentage of yield allocated to rewards (0.0 to 1.0)
        access(all) let rewardsPercent: UFix64
        /// Percentage of yield allocated to prize (0.0 to 1.0)
        access(all) let prizePercent: UFix64
        /// Percentage of yield allocated to protocol fee (0.0 to 1.0)
        access(all) let protocolFeePercent: UFix64
        
        /// Creates a FixedPercentageStrategy.
        /// IMPORTANT: Percentages must sum to exactly 1.0 (strict equality).
        /// Use values like 0.4, 0.4, 0.2 - not repeating decimals like 0.33333333.
        /// If using thirds, use 0.33, 0.33, 0.34 to sum exactly to 1.0.
        /// @param rewards - Rewards percentage (0.0-1.0)
        /// @param prize - Prize percentage (0.0-1.0)
        /// @param protocolFee - Protocol fee percentage (0.0-1.0)
        init(rewards: UFix64, prize: UFix64, protocolFee: UFix64) {
            pre {
                rewards + prize + protocolFee == 1.0:
                    "FixedPercentageStrategy: Percentages must sum to exactly 1.0, but got \(rewards) + \(prize) + \(protocolFee) = \(rewards + prize + protocolFee)"
            }
            self.rewardsPercent = rewards
            self.prizePercent = prize
            self.protocolFeePercent = protocolFee
        }
        
        /// Calculates distribution by multiplying total by each percentage.
        /// Protocol receives the remainder to ensure sum == totalAmount (handles UFix64 rounding).
        /// @param totalAmount - Total yield to distribute
        /// @return DistributionPlan with proportional amounts
        access(all) fun calculateDistribution(totalAmount: UFix64): DistributionPlan {
            let rewards = totalAmount * self.rewardsPercent
            let prize = totalAmount * self.prizePercent
            // Protocol gets the remainder to ensure sum == totalAmount
            let protocolFee = totalAmount - rewards - prize
            
            return DistributionPlan(
                rewards: rewards,
                prize: prize,
                protocolFee: protocolFee
            )
        }
        
        /// Returns strategy description with configured percentages.
        access(all) view fun getStrategyName(): String {
            return "Fixed: \(self.rewardsPercent) rewards, \(self.prizePercent) prize, \(self.protocolFeePercent) protocol"
        }
    }
    
    // ============================================================
    // ROUND RESOURCE - Per-Round TWAB Tracking (Normalized)
    // ============================================================
    
    /// Represents a single prize round with NORMALIZED TWAB tracking.
    ///
    /// TWAB uses a fixed TWAB_SCALE (1 year) for overflow protection, then normalizes
    /// by actual duration at finalization to get "average shares".
    /// Weight accumulation continues until startDraw() is called (actualEndTime).
    ///
    /// Round Lifecycle: Created → Active → Frozen → Processing → Destroyed
    
    access(all) resource Round {
        /// Unique identifier for this round (increments each draw).
        access(all) let roundID: UInt64

        /// Timestamp when this round started.
        access(all) let startTime: UFix64

        /// Target end time for this round. Admin can adjust before startDraw().
        access(self) var targetEndTime: UFix64

        /// Fixed scale for TWAB accumulation (1 year in seconds = 31,536,000).
        /// Using a fixed scale prevents overflow with large TVL and long durations.
        /// Final normalization happens at finalizeTWAB() using actual elapsed time.
        access(all) let TWAB_SCALE: UFix64

        /// Actual end time when round was finalized (set by startDraw).
        /// nil means round is still active.
        access(self) var actualEndTime: UFix64?

        /// Accumulated SCALED weight from round start to lastUpdateTime.
        /// Key: receiverID, Value: accumulated scaled weight.
        /// Scaling: shares × (elapsed / TWAB_SCALE) instead of shares × elapsed
        /// Final normalization by actual duration happens in finalizeTWAB().
        access(self) var userScaledTWAB: {UInt64: UFix64}

        /// Timestamp of last TWAB update for each user.
        /// Key: receiverID, Value: timestamp of last update.
        access(self) var userLastUpdateTime: {UInt64: UFix64}


        /// User's shares at last update (for calculating pending accumulation).
        /// Key: receiverID, Value: shares balance at last update.
        access(self) var userSharesAtLastUpdate: {UInt64: UFix64}

        /// Creates a new Round.
        /// @param roundID - Unique round identifier
        /// @param startTime - When the round starts
        /// @param targetEndTime - Minimum time before startDraw() can be called
        init(roundID: UInt64, startTime: UFix64, targetEndTime: UFix64) {
            pre {
                targetEndTime > startTime: "Target end time must be after start time. Start: \(startTime), Target: \(targetEndTime)"
            }
            self.roundID = roundID
            self.startTime = startTime
            self.targetEndTime = targetEndTime
            self.TWAB_SCALE = 31_536_000.0  // 1 year in seconds
            self.actualEndTime = nil
            self.userScaledTWAB = {}
            self.userLastUpdateTime = {}
            self.userSharesAtLastUpdate = {}
        }
        
        /// Records a share change and accumulates TWAB up to current time.
        ///
        /// Flow:
        /// 1. Accumulate pending scaled share-time for old balance
        /// 2. Update shares snapshot and timestamp for future accumulation
        ///
        /// If the round has ended (actualEndTime is set), the timestamp is capped
        /// at actualEndTime. This ensures deposits during draw processing get fair
        /// weight - new shares added after round end contribute zero weight.
        ///
        /// @param receiverID - User's receiver ID
        /// @param oldShares - Shares BEFORE the operation
        /// @param newShares - Shares AFTER the operation
        /// @param atTime - Current timestamp (will be capped at actualEndTime if round ended)
        access(contract) fun recordShareChange(
            receiverID: UInt64,
            oldShares: UFix64,
            newShares: UFix64,
            atTime: UFix64
        ) {
            // Cap time at actualEndTime if round has ended
            // This ensures deposits during draw processing get weight only up to round end
            let effectiveTime = self.actualEndTime != nil && atTime > self.actualEndTime!
                ? self.actualEndTime!
                : atTime

            // First, accumulate any pending scaled TWAB for old balance
            self.accumulatePendingTWAB(receiverID: receiverID, upToTime: effectiveTime, withShares: oldShares)

            // Update shares snapshot for future accumulation
            self.userSharesAtLastUpdate[receiverID] = newShares
            self.userLastUpdateTime[receiverID] = effectiveTime
        }

        /// Accumulates SCALED pending weight from lastUpdateTime to upToTime.
        ///
        /// Formula: scaledPending = shares × (elapsed / TWAB_SCALE)
        ///
        /// Using a fixed TWAB_SCALE (1 year) ensures overflow protection regardless
        /// of round duration or TVL. Final normalization to "average shares" happens
        /// in finalizeTWAB() using the actual elapsed time.
        ///
        /// @param receiverID - User's receiver ID
        /// @param upToTime - Time to accumulate up to
        /// @param withShares - Shares to use for accumulation
        access(self) fun accumulatePendingTWAB(
            receiverID: UInt64,
            upToTime: UFix64,
            withShares: UFix64
        ) {
            let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime

            // Only accumulate if time has passed
            if upToTime > lastUpdate {
                let elapsed = upToTime - lastUpdate
                let scaledPending = withShares * (elapsed / self.TWAB_SCALE)
                let current = self.userScaledTWAB[receiverID] ?? 0.0
                self.userScaledTWAB[receiverID] = current + scaledPending
                self.userLastUpdateTime[receiverID] = upToTime
            }
        }
        
        /// Calculates the finalized TWAB for a user at the actual round end.
        /// Called during processDrawBatch() to get each user's final weight.
        ///
        /// Returns "average shares" (normalized by actual duration).
        /// For a user who held X shares for the entire round, returns X.
        /// For a user who held X shares for half the round, returns X/2.
        ///
        /// @param receiverID - User's receiver ID
        /// @param currentShares - User's current share balance (for lazy users)
        /// @param roundEndTime - The actual end time of the round (set by startDraw)
        /// @return Normalized weight for this user (≈ average shares held)
        access(all) view fun finalizeTWAB(
            receiverID: UInt64,
            currentShares: UFix64,
            roundEndTime: UFix64
        ): UFix64 {
            // Get accumulated scaled weight so far
            let accumulated = self.userScaledTWAB[receiverID] ?? 0.0
            let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
            let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares

            var scaledPending: UFix64 = 0.0
            if roundEndTime > lastUpdate {
                let elapsed = roundEndTime - lastUpdate
                scaledPending = shares * (elapsed / self.TWAB_SCALE)
            }

            let totalScaled = accumulated + scaledPending
            let actualDuration = roundEndTime - self.startTime
            if actualDuration == 0.0 {
                return 0.0
            }

            let normalizedWeight = totalScaled * (self.TWAB_SCALE / actualDuration)

            // SAFETY: cap weight to shares
            if normalizedWeight > shares {
                return shares
            }
            return normalizedWeight
        }
        
        /// Returns the current TWAB for a user (for view functions).
        /// Calculates accumulated + pending up to current time, normalized by elapsed time.
        ///
        /// Returns "average shares" (normalized by elapsed time).
        ///
        /// @param receiverID - User's receiver ID
        /// @param currentShares - User's current share balance
        /// @param atTime - Time to calculate TWAB up to
        /// @return Current normalized weight (≈ average shares held so far)
        access(all) view fun getCurrentTWAB(
            receiverID: UInt64,
            currentShares: UFix64,
            atTime: UFix64
        ): UFix64 {
            let accumulated = self.userScaledTWAB[receiverID] ?? 0.0
            let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
            let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares

            var scaledPending: UFix64 = 0.0
            if atTime > lastUpdate {
                let elapsed = atTime - lastUpdate
                scaledPending = shares * (elapsed / self.TWAB_SCALE)
            }

            let totalScaled = accumulated + scaledPending
            let elapsedFromStart = atTime - self.startTime
            if elapsedFromStart == 0.0 {
                return 0.0
            }

            let normalizedWeight = totalScaled * (self.TWAB_SCALE / elapsedFromStart)
            if normalizedWeight > shares {
                return shares
            }
            return normalizedWeight
        }

        /// Sets the actual end time when the round is finalized.
        /// Called by startDraw() to mark the round for draw processing.
        ///
        /// @param endTime - The actual end time
        access(contract) fun setActualEndTime(_ endTime: UFix64) {
            self.actualEndTime = endTime
        }

        /// Returns the actual end time if set, nil otherwise.
        access(all) view fun getActualEndTime(): UFix64? {
            return self.actualEndTime
        }

        /// Updates the target end time for this round.
        /// Can only be called before startDraw() finalizes the round.
        ///
        /// SAFETY: When shortening, the new target must be >= current block timestamp.
        /// This prevents a bug where already-accumulated time could exceed the new
        /// target duration, causing weight > shares (violating the TWAB invariant).
        ///
        /// @param newTarget - New target end time (must be after start time and >= now if shortening)
        access(contract) fun setTargetEndTime(newTarget: UFix64) {
            pre {
                self.actualEndTime == nil: "Cannot change target after startDraw()"
                newTarget > self.startTime: "Target must be after start time. Start: \(self.startTime), NewTarget: \(newTarget)"
            }
            // SAFETY CHECK: When shortening, new target must be >= current time
            // This ensures no user has accumulated time beyond the new target
            let now = getCurrentBlock().timestamp
            if newTarget < self.targetEndTime {
                // Shortening - must be >= current time to prevent weight > shares bug
                assert(
                    newTarget >= now,
                    message: "Cannot shorten target to before current time. Now: \(now), NewTarget: \(newTarget)"
                )
            }
            self.targetEndTime = newTarget
        }

        /// Returns whether this round has reached its target end time.
        /// Used for "can we start a draw" check.
        /// OPTIMIZATION: Uses pre-computed configuredEndTime.
        access(all) view fun hasEnded(): Bool {
            return getCurrentBlock().timestamp >= self.targetEndTime
        }

        /// Returns the target end time for this round.
        access(all) view fun getTargetEndTime(): UFix64 {
            return self.targetEndTime
        }

        /// Returns the target end time (same as getTargetEndTime for backward compatibility).
        /// Used for gap period detection.
        /// OPTIMIZATION: Returns pre-computed value.
        access(all) view fun getConfiguredEndTime(): UFix64 {
            return self.targetEndTime
        }


        /// Returns the round ID.
        access(all) view fun getRoundID(): UInt64 {
            return self.roundID
        }


        /// Returns the round start time.
        access(all) view fun getStartTime(): UFix64 {
            return self.startTime
        }

        /// Returns the round duration (computed as targetEndTime - startTime).
        /// Note: This is the target duration, not actual duration.
        access(all) view fun getDuration(): UFix64 {
            return self.targetEndTime - self.startTime
        }

        /// Returns the target end time (same as getTargetEndTime for backward compatibility).
        access(all) view fun getEndTime(): UFix64 {
            return self.targetEndTime
        }


        /// Returns whether a user has been initialized in this round.
        access(all) view fun isUserInitialized(receiverID: UInt64): Bool {
            return self.userLastUpdateTime[receiverID] != nil
        }
    }
    
    // ============================================================
    // SHARE TRACKER RESOURCE
    // ============================================================
    
    /// ERC4626-style share accounting ledger with virtual offset protection against inflation attacks.
    /// 
    /// This resource manages share-based accounting for user deposits:
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
    /// - totalAssets should approximately equal Pool.allocatedRewards
    /// - sum(userShares) == totalShares
    /// - share price may increase (yield) or decrease (loss socialization)
    access(all) resource ShareTracker {
        /// Total shares outstanding across all users.
        access(self) var totalShares: UFix64
        
        /// Total asset value held (principal + accrued yield).
        /// This determines share price: price = (totalAssets + VIRTUAL) / (totalShares + VIRTUAL)
        access(self) var totalAssets: UFix64
        
        /// Mapping of receiverID to their share balance.
        access(self) let userShares: {UInt64: UFix64}
        
        /// Cumulative yield distributed since pool creation (for statistics).
        access(all) var totalDistributed: UFix64
        
        /// Type of fungible token vault this tracker handles.
        access(self) let vaultType: Type
        
        /// Initializes a new ShareTracker.
        /// @param vaultType - Type of fungible token to track
        init(vaultType: Type) {
            self.totalShares = 0.0
            self.totalAssets = 0.0
            self.userShares = {}
            self.totalDistributed = 0.0
            self.vaultType = vaultType
        }
        
        /// Accrues yield to the rewards pool by increasing totalAssets.
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
            let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
            let dustAmount = amount * PrizeLinkedAccounts.VIRTUAL_SHARES / effectiveShares
            let actualRewards = amount - dustAmount
            
            // Increase total assets, which increases share price for everyone
            self.totalAssets = self.totalAssets + actualRewards
            self.totalDistributed = self.totalDistributed + actualRewards
            
            return actualRewards
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
            
            self.totalAssets = self.totalAssets - actualDecrease
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
        /// @param dustThreshold - If remaining balance would be below this, burn all shares (prevents dust)
        /// @return The actual amount withdrawn
        access(contract) fun withdraw(receiverID: UInt64, amount: UFix64, dustThreshold: UFix64): UFix64 {
            if amount == 0.0 {
                return 0.0
            }

            // Validate user has sufficient shares
            let userShareBalance = self.userShares[receiverID] ?? 0.0
            assert(
                userShareBalance > 0.0,
                message: "ShareTracker.withdraw: No shares to withdraw for receiver \(receiverID)"
            )
            assert(
                self.totalShares > 0.0 && self.totalAssets > 0.0,
                message: "ShareTracker.withdraw: Invalid tracker state - totalShares: \(self.totalShares), totalAssets: \(self.totalAssets)"
            )

            // Validate user has sufficient balance
            let currentAssetValue = self.convertToAssets(userShareBalance)
            assert(
                amount <= currentAssetValue,
                message: "ShareTracker.withdraw: Insufficient balance - requested \(amount) but receiver \(receiverID) only has \(currentAssetValue)"
            )

            // Calculate shares to burn at current share price
            let calculatedSharesToBurn = self.convertToShares(amount)

            // DUST PREVENTION: Determine if we should burn all shares instead of calculated amount.
            // This happens when:
            // 1. Withdrawing full balance (amount >= currentAssetValue)
            // 2. Rounding would cause underflow (calculatedSharesToBurn > userShareBalance)
            // 3. Remaining balance would be below dust threshold (new!)
            let remainingValueAfterBurn = currentAssetValue - amount
            let wouldLeaveDust = remainingValueAfterBurn < dustThreshold && remainingValueAfterBurn > 0.0

            let burnAllShares = amount >= currentAssetValue
                || calculatedSharesToBurn > userShareBalance
                || wouldLeaveDust

            let sharesToBurn = burnAllShares ? userShareBalance : calculatedSharesToBurn

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
            let effectiveShares = self.totalShares + PrizeLinkedAccounts.VIRTUAL_SHARES
            let effectiveAssets = self.totalAssets + PrizeLinkedAccounts.VIRTUAL_ASSETS
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

        /// Cleans up zero-share entries using forEachKey (avoids .keys memory copy).
        /// @param limit - Maximum entries to process (for gas management)
        /// @return Number of entries cleaned
        access(contract) fun cleanupZeroShareEntries(limit: Int): Int {
            // Collect keys to check (can't access self inside closure)
            var keysToCheck: [UInt64] = []
            var count = 0
            
            self.userShares.forEachKey(fun (key: UInt64): Bool {
                if count >= limit {
                    return false  // Early exit for gas management
                }
                keysToCheck.append(key)
                count = count + 1
                return true
            })
            
            // Check and remove zero entries
            var cleaned = 0
            for key in keysToCheck {
                if self.userShares[key] == 0.0 {
                    let _ = self.userShares.remove(key: key)
                    cleaned = cleaned + 1
                }
            }
            
            return cleaned
        }
    }
    
    // ============================================================
    // LOTTERY DISTRIBUTOR RESOURCE
    // ============================================================
    
    /// Manages the prize pool and NFT prizes.
    /// 
    /// This resource handles:
    /// - Fungible token prize pool (accumulated from yield distribution)
    /// - Available NFT prizes (deposited by admin, awaiting draw)
    /// - Pending NFT claims (awarded to winners, awaiting user pickup)
    /// - Draw round tracking
    /// 
    /// PRIZE FLOW:
    /// 1. Yield processed → prize portion added to prizeVault
    /// 2. NFTs deposited by admin → stored in nftPrizes
    /// 3. Draw completes → prizes withdrawn and awarded
    /// 4. NFT prizes → stored in pendingNFTClaims for winner
    /// 5. Winner claims → NFT transferred to their collection
    access(all) resource PrizeDistributor {
        /// Vault holding fungible token prizes.
        /// Balance is the available prize pool for the next draw.
        access(self) var prizeVault: @{FungibleToken.Vault}
        
        /// NFTs available as prizes, keyed by NFT UUID.
        /// Admin deposits NFTs here; winner selection strategy assigns them.
        access(self) var nftPrizes: @{UInt64: {NonFungibleToken.NFT}}
        
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
        
        /// Initializes a new PrizeDistributor with an empty prize vault.
        /// @param vaultType - Type of fungible token for prizes
        init(vaultType: Type) {
            self.prizeVault <- DeFiActionsUtils.getEmptyVault(vaultType)
            self.nftPrizes <- {}
            self.pendingNFTClaims <- {}
            self._prizeRound = 0
            self.totalPrizesDistributed = 0.0
        }
        
        /// Adds funds to the prize pool.
        /// Called during yield processing when prize portion is allocated.
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
            self.nftPrizes[nftID] <-! nft
        }
        
        /// Withdraws an available NFT prize (before it's awarded).
        /// Used by admin to recover NFTs or update prize pool.
        /// @param nftID - UUID of the NFT to withdraw
        /// @return The withdrawn NFT resource
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            if let nft <- self.nftPrizes.remove(key: nftID) {
                return <- nft
            }
            panic("NFT not found in prize vault: \(nftID)")
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
                panic("Failed to store NFT in pending claims. NFTID: \(nftID), receiverID: \(receiverID)")
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
            return self.nftPrizes.keys
        }
        
        /// Borrows a reference to an available NFT prize (read-only).
        /// @param nftID - UUID of the NFT
        /// @return Reference to the NFT, or nil if not found
        access(all) view fun borrowNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return &self.nftPrizes[nftID]
        }

        /// Claims a pending NFT and returns it to the caller.
        /// Called when a winner picks up their NFT prize.
        /// @param receiverID - Winner's receiver ID
        /// @param nftIndex - Index in the pending claims array (0-based)
        /// @return The claimed NFT resource
        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.pendingNFTClaims[receiverID] != nil: "No pending NFTs for this receiver"
                nftIndex >= 0: "NFT index cannot be negative"
                nftIndex < (self.pendingNFTClaims[receiverID]?.length ?? 0): "Invalid NFT index"
            }
            if let nftsRef = &self.pendingNFTClaims[receiverID] as auth(Remove) &[{NonFungibleToken.NFT}]? {
                return <- nftsRef.remove(at: nftIndex)
            }
            panic("Failed to access pending NFT claims. receiverID: \(receiverID), nftIndex: \(nftIndex)")
        }

        /// Cleans up empty pendingNFTClaims entries using forEachKey (avoids .keys memory copy).
        /// @param limit - Maximum entries to process (for gas management)
        /// @return Number of entries cleaned
        access(contract) fun cleanupEmptyNFTClaimEntries(limit: Int): Int {
            // Collect keys to check (can't access self inside closure)
            var keysToCheck: [UInt64] = []
            var count = 0
            
            self.pendingNFTClaims.forEachKey(fun (key: UInt64): Bool {
                if count >= limit {
                    return false  // Early exit for gas management
                }
                keysToCheck.append(key)
                count = count + 1
                return true
            })
            
            // Check and remove empty entries
            var cleaned = 0
            for key in keysToCheck {
                if self.pendingNFTClaims[key]?.length == 0 {
                    if let emptyArray <- self.pendingNFTClaims.remove(key: key) {
                        destroy emptyArray
                    }
                    cleaned = cleaned + 1
                }
            }
            
            return cleaned
        }
    }
    
    // ============================================================
    // PRIZE DRAW RECEIPT RESOURCE
    // ============================================================
    
    /// Represents a pending prize draw that is waiting for randomness.
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
    /// so late deposits/withdrawals cannot affect prize odds for this draw.
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
                assert(split >= 0.0 && split <= 1.0, message: "Each split must be between 0 and 1. split: \(split), index: \(splitIndex)")
                total = total + split
                splitIndex = splitIndex + 1
            }
            
            assert(total == 1.0, message: "Prize splits must sum to 1.0. actual total: \(total)")
            
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
    
    /// Configuration parameters for a prize-linked accounts pool.
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
        
        /// Minimum time (seconds) between prize draws.
        /// Determines epoch length and TWAB accumulation period.
        access(all) var drawIntervalSeconds: UFix64
        
        /// Yield source connection (implements both deposit and withdraw).
        /// Handles depositing funds to earn yield and withdrawing for prizes/redemptions.
        /// Immutable after pool creation.
        access(contract) let yieldConnector: {DeFiActions.Sink, DeFiActions.Source}
        
        /// Strategy for distributing yield between rewards, prize, and protocol fee.
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
    /// Resource holding prize selection data - implemented as a resource to enable zero-copy reference passing.
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

            // OPTIMIZED: Binary search with rejection sampling O(k * log n) average
            // Uses binary search for fast lookup, re-samples on collision
            // More efficient than linear scan O(n * k) when k << n
            var winners: [UInt64] = []
            var selectedIndices: {Int: Bool} = {}
            let maxRetries = receiverCount * 3  // Safety limit to avoid infinite loops

            var selected = 0
            var retries = 0
            while selected < actualCount && retries < maxRetries {
                let rng = prg.nextUInt64()
                let scaledRandom = UFix64(rng % self.RANDOM_SCALING_FACTOR) / self.RANDOM_SCALING_DIVISOR
                let randomValue = scaledRandom * self.totalWeight

                // Use binary search to find candidate winner
                let candidateIdx = self.findWinnerIndex(randomValue: randomValue)

                // Check if already selected (rejection sampling)
                if selectedIndices[candidateIdx] != nil {
                    retries = retries + 1
                    continue
                }

                // Accept this winner
                winners.append(self.receiverIDs[candidateIdx])
                selectedIndices[candidateIdx] = true
                selected = selected + 1
                retries = 0  // Reset retry counter on success
            }

            // Fallback: if we hit max retries (very unlikely), fill remaining with unselected
            if selected < actualCount {
                for i in InclusiveRange(0, receiverCount - 1) {
                    if selected >= actualCount {
                        break
                    }
                    if selectedIndices[i] == nil {
                        winners.append(self.receiverIDs[i])
                        selectedIndices[i] = true
                        selected = selected + 1
                    }
                }
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
    // POOL RESOURCE - Core Prize Rewards Pool
    // ============================================================
    
    /// The main prize-linked accounts pool resource.
    /// 
    /// Pool is the central coordinator that manages:
    /// - User deposits and withdrawals
    /// - Yield generation and distribution
    /// - Prize draws and prize distribution
    /// - Emergency mode and health monitoring
    /// 
    /// ARCHITECTURE:
    /// Pool contains nested resources:
    /// - ShareTracker: Share-based accounting
    /// - PrizeDistributor: Prize pool and NFT management
    /// - RandomConsumer: On-chain randomness for fair draws
    /// 
    /// LIFECYCLE:
    /// 1. Admin creates pool with createPool()
    /// 2. Users deposit via PoolPositionCollection.deposit()
    /// 3. Yield accrues from connected DeFi source
    /// 4. syncWithYieldSource() distributes yield per strategy
    /// 5. Admin calls startDraw() → completeDraw() for prize
    /// 6. Winners receive auto-compounded prizes
    /// 7. Users withdraw via PoolPositionCollection.withdraw()
    /// 
    /// DESTRUCTION:
    /// In Cadence 1.0+, nested resources are automatically destroyed with Pool.
    /// Order: pendingDrawReceipt → randomConsumer → shareTracker → prizeDistributor
    /// Protocol fee should be forwarded before destruction.
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
        
        /// Mapping of receiverID to their lifetime prize winnings (cumulative).
        access(self) let receiverTotalEarnedPrizes: {UInt64: UFix64}
        
        /// Maps receiverID to their index in registeredReceiverList.
        /// Used for O(1) lookup and O(1) unregistration via swap-and-pop.
        access(self) var registeredReceivers: {UInt64: Int}
        
        /// Sequential list of registered receiver IDs.
        /// Used for O(n) iteration during batch processing without array allocation.
        access(self) var registeredReceiverList: [UInt64]
        
        /// Mapping of receiverID to bonus prize weight.
        /// Bonus weight represents equivalent token deposit for the full round duration.
        /// A bonus of 5.0 gives the same prize weight as holding 5 tokens for the entire round.
        access(self) let receiverBonusWeights: {UInt64: UFix64}
        
        /// Tracks which receivers are sponsors (prize-ineligible).
        /// Sponsors earn rewards yield but cannot win prizes.
        /// Key: receiverID (UUID of SponsorPositionCollection), Value: true if sponsor
        access(self) let sponsorReceivers: {UInt64: Bool}
        
        /// Maps receiverID to their last known owner address.
        /// Updated on each deposit/withdraw to track current owner.
        /// Address may become stale if resource is transferred without interaction.
        /// WARNING: This is not a source of truth.  Used only for event emission  
        access(self) let receiverAddresses: {UInt64: Address}
        
        // ============================================================
        // ACCOUNTING STATE
        // ============================================================
        // 
        // KEY RELATIONSHIPS:
        // 
        // allocatedRewards: Sum of user deposits + auto-compounded prizes
        //   - Excludes rewards interest (interest is tracked in share price)
        //   - Updated on: deposit (+), prize awarded (+), withdraw (-)
        //   - This is the "no-loss guarantee" amount
        // 
        // ============================================================
        // YIELD ALLOCATION TRACKING
        // ============================================================
        // These three variables partition the yield source balance into buckets.
        // Their sum (getTotalAllocatedFunds()) represents the total tracked assets.
        // syncWithYieldSource() syncs these variables with the yield source balance.
        //
        // User portion of yield source balance
        //   - Includes deposits + won prizes + accrued rewards yield
        //   - Updated on: deposit (+), prize (+), rewards yield (+), withdraw (-)
        access(all) var allocatedRewards: UFix64
        //
        // allocatedPrizeYield: Prize portion awaiting transfer to prize pool
        //   - Accumulates as yield is earned
        //   - Transferred to prize pool vault at draw time
        access(all) var allocatedPrizeYield: UFix64
        //
        // allocatedProtocolFee: Protocol portion awaiting transfer to recipient
        //   - Accumulates as yield is earned (includes rounding dust)
        //   - Transferred to recipient or unclaimed vault at draw time
        // 
        // ============================================================

        /// Timestamp of the last completed prize draw.
        access(all) var lastDrawTimestamp: UFix64
        
        // ============================================================
        // YIELD ALLOCATION VARIABLES
        // Sum of these three = yield source balance (see getTotalAllocatedFunds)
        // ============================================================
        
        /// User allocation: deposits + prizes won + accrued rewards yield.
        /// This is the portion of the yield source that belongs to users.
        
        
        /// Prize allocation: yield awaiting transfer to prize pool at draw time.
        /// Stays in yield source earning until materialized during draw.
        
        
        /// Protocol allocation: yield awaiting transfer to recipient at draw time.
        /// Stays in yield source earning until materialized during draw.
        access(all) var allocatedProtocolFee: UFix64
        
        /// Cumulative protocol fee amount forwarded to recipient.
        access(all) var totalProtocolFeeForwarded: UFix64
        
        /// Capability to protocol fee recipient for forwarding at draw time.
        /// If nil, protocol fee goes to unclaimedProtocolFeeVault instead.
        access(self) var protocolFeeRecipientCap: Capability<&{FungibleToken.Receiver}>?
        
        /// Holds protocol fee when no recipient is configured.
        /// Admin can withdraw from this vault at any time.
        access(self) var unclaimedProtocolFeeVault: @{FungibleToken.Vault}
        
        // ============================================================
        // NESTED RESOURCES
        // ============================================================
        
        /// Manages rewards: ERC4626-style share accounting.
        access(self) let shareTracker: @ShareTracker
        
        /// Manages prize: prize pool, NFTs, pending claims.
        access(self) let prizeDistributor: @PrizeDistributor
        
        /// Holds pending draw receipt during two-phase draw process.
        /// Set during startDraw(), consumed during completeDraw().
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        
        /// On-chain randomness consumer for fair prize selection.
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        // ============================================================
        // ROUND-BASED TWAB TRACKING
        // ============================================================
        
        /// Current active round for TWAB accumulation.
        /// Deposits and withdrawals accumulate TWAB in this round.
        /// During draw processing, this round has actualEndTime set and is being finalized.
        /// nil indicates the pool is in intermission (between rounds).
        /// Destroyed at completeDraw(), recreated at startNextRound().
        access(self) var activeRound: @Round?

        /// ID of the last completed round (for intermission state queries).
        /// Updated when completeDraw() finishes, used by getCurrentRoundID() during intermission.
        access(self) var lastCompletedRoundID: UInt64
        
        // ============================================================
        // BATCH PROCESSING STATE (for prize weight capture)
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
            self.emergencyConfig = emergencyConfig ?? PrizeLinkedAccounts.createDefaultEmergencyConfig()
            self.consecutiveWithdrawFailures = 0
            
            // Initialize user tracking
            self.receiverTotalEarnedPrizes = {}
            self.registeredReceivers = {}
            self.registeredReceiverList = []
            self.receiverBonusWeights = {}
            self.sponsorReceivers = {}
            self.receiverAddresses = {}
            
            // Initialize accounting
            self.allocatedRewards = 0.0
            self.lastDrawTimestamp = 0.0
            self.allocatedPrizeYield = 0.0
            self.allocatedProtocolFee = 0.0
            self.totalProtocolFeeForwarded = 0.0
            self.protocolFeeRecipientCap = nil
            
            // Create vault for unclaimed protocol fee (when no recipient configured)
            self.unclaimedProtocolFeeVault <- DeFiActionsUtils.getEmptyVault(config.assetType)
            
            // Create nested resources
            self.shareTracker <- create ShareTracker(vaultType: config.assetType)
            self.prizeDistributor <- create PrizeDistributor(vaultType: config.assetType)
            
            // Initialize draw state
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
            
            // Initialize round-based TWAB tracking
            // Create initial round starting now with configured draw interval determining target end time
            let now = getCurrentBlock().timestamp
            self.activeRound <- create Round(
                roundID: 1,
                startTime: now,
                targetEndTime: now + config.drawIntervalSeconds
            )
            self.lastCompletedRoundID = 0
            
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
        /// @param ownerAddress - Optional owner address for address resolution
        access(contract) fun registerReceiver(receiverID: UInt64, ownerAddress: Address?) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            // Store index pointing to the end of the list
            let index = self.registeredReceiverList.length
            self.registeredReceivers[receiverID] = index
            self.registeredReceiverList.append(receiverID)
            
            // Store address for address resolution if provided
            self.updatereceiverAddress(receiverID: receiverID, ownerAddress: ownerAddress)
        }
        
        /// Resolves the last known owner address of a receiver.
        /// Returns the address stored during the last deposit/withdraw interaction.
        /// Address may be stale if resource was transferred without interaction.
        /// @param receiverID - UUID of the PoolPositionCollection
        /// @return Last known owner address, or nil if unknown
        access(all) view fun getReceiverOwnerAddress(receiverID: UInt64): Address? {
            return self.receiverAddresses[receiverID]
        }
        
        /// Updates the stored owner address for a receiver only if it has changed.
        /// Saves storage write costs when address remains the same.
        /// @param receiverID - UUID of the PoolPositionCollection
        /// @param ownerAddress - Optional new owner address to store
        access(contract) fun updatereceiverAddress(receiverID: UInt64, ownerAddress: Address?) {
            if let addr = ownerAddress {
                if self.receiverAddresses[receiverID] != addr {
                    self.receiverAddresses[receiverID] = addr
                }
            }
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
            let _removedReceiver = self.registeredReceiverList.removeLast()
            // Remove from dictionary
            let _removedIndex = self.registeredReceivers.remove(key: receiverID)
            
            // Clean up address mapping
            self.receiverAddresses.remove(key: receiverID)
        }
        
        /// Cleans up stale dictionary entries and ghost receivers to manage storage growth.
        /// 
        /// Handles:
        /// 1. Ghost receivers - users with 0 shares still in registeredReceiverList
        /// 2. userShares entries with 0.0 value
        /// 3. Empty pendingNFTClaims arrays
        /// 
        /// IMPORTANT: Cannot be called during active draw processing (would corrupt indices).
        /// Should be called periodically (e.g., after draws, weekly) by admin.
        /// Uses limit to avoid gas limits - call multiple times if needed.
        /// 
        /// GAS OPTIMIZATION:
        /// - Uses forEachKey instead of .keys (avoids O(n) memory copy)
        /// - All cleanups have limits for gas management
        /// 
        /// @param limit - Max entries to process per cleanup type
        /// @return Dictionary with cleanup counts
        /// Cleans up stale entries with cursor-based iteration.
        /// 
        /// @param startIndex - Index to start iterating from in registeredReceiverList
        /// @param limit - Max receivers to process in this call
        /// @return Dictionary with cleanup counts and nextIndex for continuation
        access(contract) fun cleanupStaleEntries(startIndex: Int, limit: Int): {String: Int} {
            pre {
                self.pendingSelectionData == nil: "Cannot cleanup during active draw - would corrupt batch indices"
            }
            
            var ghostReceiversCleaned = 0
            var userSharesCleaned = 0
            var pendingNFTClaimsCleaned = 0
            
            let totalReceivers = self.registeredReceiverList.length
            
            // 1. Clean ghost receivers (0-share users still in registeredReceiverList)
            // Use cursor-based iteration with swap-and-pop awareness
            var i = startIndex < totalReceivers ? startIndex : totalReceivers
            var processed = 0
            
            while i < self.registeredReceiverList.length && processed < limit {
                let receiverID = self.registeredReceiverList[i]
                let shares = self.shareTracker.getUserShares(receiverID: receiverID)
                
                if shares == 0.0 {
                    // This receiver is a ghost - unregister them
                    self.unregisterReceiver(receiverID: receiverID)
                    ghostReceiversCleaned = ghostReceiversCleaned + 1
                    // Don't increment i - swap-and-pop moved a new element here
                } else {
                    i = i + 1
                }
                processed = processed + 1
            }
            
            // 2. Clean userShares with 0 values (forEachKey avoids .keys memory copy)
            userSharesCleaned = self.shareTracker.cleanupZeroShareEntries(limit: limit)
            
            // 3. Clean empty pendingNFTClaims arrays (forEachKey avoids .keys memory copy)
            pendingNFTClaimsCleaned = self.prizeDistributor.cleanupEmptyNFTClaimEntries(limit: limit)
            
            return {
                "ghostReceivers": ghostReceiversCleaned,
                "userShares": userSharesCleaned,
                "pendingNFTClaims": pendingNFTClaimsCleaned,
                "nextIndex": i,
                "totalReceivers": self.registeredReceiverList.length
            }
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
            let balanceHealthy = balance >= self.allocatedRewards * threshold
            
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
        /// Routes funds to specified destination (Rewards or Prize).
        /// 
        /// For Rewards: Deposits to yield source and accrues yield to share price.
        /// For Prize: Adds directly to prize pool.
        /// 
        /// @param destination - Where to route funds (Rewards or Prize)
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
                self.emergencyState == PoolEmergencyState.Normal: "Direct funding only in normal state. Current state: \(self.emergencyState.rawValue)"
                from.getType() == self.config.assetType: "Invalid vault type. Expected: \(self.config.assetType.identifier), got: \(from.getType().identifier)"
            }
            
            switch destination {
                case PoolFundingDestination.Prize:
                    // Prize funding goes directly to prize vault
                    self.prizeDistributor.fundPrizePool(vault: <- from)
                    
                case PoolFundingDestination.Rewards:
                    // Rewards funding requires depositors to receive the yield
                    assert(
                        self.shareTracker.getTotalShares() > 0.0,
                        message: "Cannot fund rewards with no depositors - funds would be orphaned. Amount: \(from.balance), totalShares: \(self.shareTracker.getTotalShares())"
                    )
                    
                    let amount = from.balance

                    // Deposit to yield source to earn on the funds
                    self.depositToYieldSourceFull(<- from)

                    // Accrue yield to share price (minus dust to virtual shares)
                    let actualRewards = self.shareTracker.accrueYield(amount: amount)
                    let dustAmount = amount - actualRewards
                    self.allocatedRewards = self.allocatedRewards + actualRewards
                    emit RewardsYieldAccrued(poolID: self.poolID, amount: actualRewards)
                    
                    // Route dust to pending protocol
                    if dustAmount > 0.0 {
                        emit RewardsRoundingDustToProtocolFee(poolID: self.poolID, amount: dustAmount)
                        self.allocatedProtocolFee = self.allocatedProtocolFee + dustAmount
                    }
                    
                default:
                    panic("Unsupported funding destination. Destination rawValue: \(destination.rawValue)")
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
        /// 5. Update accounting (allocatedRewards)
        /// 6. Deposit to yield source
        /// 
        /// TWAB HANDLING:
        /// - If in active round: recordShareChange() accumulates TWAB up to now
        /// - If in gap period (round ended, startDraw not called): finalize in ended round
        ///   with actualEndTime, new round will use lazy fallback
        /// - If pending draw exists: finalize user in that round with actual end time
        /// 
        /// @param from - Vault containing funds to deposit (consumed)
        /// @param receiverID - UUID of the depositor's PoolPositionCollection
        /// @param ownerAddress - Optional owner address for address resolution
        access(contract) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64, ownerAddress: Address?) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive. Amount: \(from.balance)"
                from.getType() == self.config.assetType: "Invalid vault type. Expected: \(self.config.assetType.identifier), got: \(from.getType().identifier)"
                self.shareTracker.getTotalAssets() + from.balance <= PrizeLinkedAccounts.SAFE_MAX_TVL: "Deposit would exceed pool TVL capacity"
            }

            // Auto-register if not registered (handles re-deposits after full withdrawal)
            if self.registeredReceivers[receiverID] == nil {
                self.registerReceiver(receiverID: receiverID, ownerAddress: ownerAddress)
            } else {
                // Update address if provided (tracks current owner)
                self.updatereceiverAddress(receiverID: receiverID, ownerAddress: ownerAddress)
            }

            // Enforce state-specific deposit rules
            switch self.emergencyState {
                case PoolEmergencyState.Normal:
                    // Normal: enforce minimum deposit
                    assert(from.balance >= self.config.minimumDeposit, message: "Below minimum deposit. Required: \(self.config.minimumDeposit), got: \(from.balance)")
                case PoolEmergencyState.PartialMode:
                    // Partial: enforce deposit limit
                    let depositLimit = self.emergencyConfig.partialModeDepositLimit ?? 0.0
                    assert(depositLimit > 0.0, message: "Partial mode deposit limit not configured. ReceiverID: \(receiverID)")
                    assert(from.balance <= depositLimit, message: "Deposit exceeds partial mode limit. Limit: \(depositLimit), got: \(from.balance)")
                case PoolEmergencyState.EmergencyMode:
                    // Emergency: no deposits allowed
                    panic("Deposits disabled in emergency mode. Withdrawals only. ReceiverID: \(receiverID), amount: \(from.balance)")
                case PoolEmergencyState.Paused:
                    // Paused: nothing allowed
                    panic("Pool is paused. No operations allowed. ReceiverID: \(receiverID), amount: \(from.balance)")
            }

            // Process pending yield/deficit before deposit to ensure fair share price
            if self.needsSync() {
                self.syncWithYieldSource()
            }
            
            let amount = from.balance
            let now = getCurrentBlock().timestamp
            
            // Get current shares BEFORE the deposit for TWAB calculation
            let oldShares = self.shareTracker.getUserShares(receiverID: receiverID)
            
            // Record deposit in share tracker (mints shares)
            let newSharesMinted = self.shareTracker.deposit(receiverID: receiverID, amount: amount)
            let newShares = oldShares + newSharesMinted
            
            // Update TWAB in the active round (if exists)
            if let round = &self.activeRound as &Round? {
                round.recordShareChange(
                    receiverID: receiverID,
                    oldShares: oldShares,
                    newShares: newShares,
                    atTime: now 
                )
            }

            // Update pool total
            self.allocatedRewards = self.allocatedRewards + amount
            
            // Deposit to yield source to start earning
            self.depositToYieldSourceFull(<- from)

            emit Deposited(poolID: self.poolID, receiverID: receiverID, amount: amount, shares: newSharesMinted, ownerAddress: ownerAddress)
        }
        
        /// Deposits funds as a sponsor (prize-ineligible).
        /// 
        /// Called internally by SponsorPositionCollection.deposit().
        /// 
        /// Sponsors earn rewards yield through share price appreciation but
        /// are NOT eligible to win prizes. This is useful for:
        /// - Protocol treasuries seeding initial liquidity
        /// - Foundations incentivizing participation without competing
        /// - Users who want yield but don't want prize exposure
        /// 
        /// DIFFERENCES FROM REGULAR DEPOSIT:
        /// - Not added to registeredReceiverList (no prize eligibility)
        /// - No TWAB tracking (no prize weight needed)
        /// - Tracked in sponsorReceivers mapping instead
        /// 
        /// @param from - Vault containing funds to deposit (consumed)
        /// @param receiverID - UUID of the sponsor's SponsorPositionCollection
        /// @param ownerAddress - Owner address of the SponsorPositionCollection (passed directly since sponsors don't use capabilities)
        access(contract) fun sponsorDeposit(from: @{FungibleToken.Vault}, receiverID: UInt64, ownerAddress: Address?) {
            pre {
                from.balance > 0.0: "Deposit amount must be positive. Amount: \(from.balance)"
                from.getType() == self.config.assetType: "Invalid vault type. Expected: \(self.config.assetType.identifier), got: \(from.getType().identifier)"
                self.shareTracker.getTotalAssets() + from.balance <= PrizeLinkedAccounts.SAFE_MAX_TVL: "Deposit would exceed pool TVL capacity"
            }

            // Enforce state-specific deposit rules
            switch self.emergencyState {
                case PoolEmergencyState.Normal:
                    // Normal: enforce minimum deposit
                    assert(from.balance >= self.config.minimumDeposit, message: "Below minimum deposit. Required: \(self.config.minimumDeposit), got: \(from.balance)")
                case PoolEmergencyState.PartialMode:
                    // Partial: enforce deposit limit
                    let depositLimit = self.emergencyConfig.partialModeDepositLimit ?? 0.0
                    assert(depositLimit > 0.0, message: "Partial mode deposit limit not configured. ReceiverID: \(receiverID)")
                    assert(from.balance <= depositLimit, message: "Deposit exceeds partial mode limit. Limit: \(depositLimit), got: \(from.balance)")
                case PoolEmergencyState.EmergencyMode:
                    // Emergency: no deposits allowed
                    panic("Deposits disabled in emergency mode. Withdrawals only. ReceiverID: \(receiverID), amount: \(from.balance)")
                case PoolEmergencyState.Paused:
                    // Paused: nothing allowed
                    panic("Pool is paused. No operations allowed. ReceiverID: \(receiverID), amount: \(from.balance)")
            }

            // Process pending yield/deficit before deposit to ensure fair share price
            if self.needsSync() {
                self.syncWithYieldSource()
            }

            let amount = from.balance

            // Record deposit in share tracker (mints shares - same as regular deposit)
            let newSharesMinted = self.shareTracker.deposit(receiverID: receiverID, amount: amount)
            
            // Mark as sponsor (prize-ineligible)
            self.sponsorReceivers[receiverID] = true
            
            // Update pool total
            self.allocatedRewards = self.allocatedRewards + amount
            
            // Deposit to yield source to start earning
            self.depositToYieldSourceFull(<- from)

            // NOTE: No registeredReceiverList registration - sponsors are NOT prize-eligible
            // NOTE: No TWAB/Round tracking - no prize weight needed
            
            emit SponsorDeposited(poolID: self.poolID, receiverID: receiverID, amount: amount, shares: newSharesMinted, ownerAddress: ownerAddress)
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
        /// 7. Update accounting (allocatedRewards)
        /// 
        /// TWAB HANDLING:
        /// - If in active round: recordShareChange() accumulates TWAB up to now
        /// - If in gap period: finalize in ended round with actual end time
        /// - If pending draw exists: finalize user in that round with actual end time
        /// 
        /// DUST PREVENTION & FULL WITHDRAWAL HANDLING:
        /// When remaining balance after withdrawal would be below minimumDeposit, this is
        /// treated as a "full withdrawal" - all shares are burned and the user receives
        /// whatever is available from the yield source. This prevents dust accumulation
        /// and handles rounding errors gracefully. Users don't need to calculate exact
        /// amounts; requesting their approximate full balance will cleanly exit the pool.
        ///
        /// LIQUIDITY FAILURE BEHAVIOR:
        /// If the yield source has insufficient liquidity for a non-full withdrawal,
        /// this function returns an EMPTY vault (0 tokens). This:
        /// - Simplifies accounting (no unexpected partial share burns)
        /// - Enables clear failure detection via WithdrawalFailure events
        /// - Triggers emergency mode after consecutive failures
        /// For partial withdrawals, users should check available liquidity first via
        /// getYieldSourceBalance().
        /// 
        /// @param amount - Amount to withdraw (must be > 0)
        /// @param receiverID - UUID of the withdrawer's PoolPositionCollection
        /// @param ownerAddress - Optional owner address for tracking current owner
        /// @return Vault containing withdrawn funds (may be empty on failure)
        access(contract) fun withdraw(amount: UFix64, receiverID: UInt64, ownerAddress: Address?): @{FungibleToken.Vault} {
            pre {
                amount > 0.0: "Withdraw amount must be greater than 0"
                self.registeredReceivers[receiverID] != nil || self.sponsorReceivers[receiverID] == true: "Receiver not registered. ReceiverID: \(receiverID)"
            }
            
            // Update stored address if provided (tracks current owner)
            self.updatereceiverAddress(receiverID: receiverID, ownerAddress: ownerAddress)
            
            // Paused pool: nothing allowed
            assert(self.emergencyState != PoolEmergencyState.Paused, message: "Pool is paused - no operations allowed. ReceiverID: \(receiverID), amount: \(amount)")
            
            // In emergency mode, check if we can auto-recover
            if self.emergencyState == PoolEmergencyState.EmergencyMode {
                let _ = self.checkAndAutoRecover()
            }
            
            // Process pending yield/deficit before withdrawal (if in normal mode)
            if self.emergencyState == PoolEmergencyState.Normal && self.needsSync() {
                self.syncWithYieldSource()
            }
            
            // Validate user has sufficient balance
            let totalBalance = self.shareTracker.getUserAssetValue(receiverID: receiverID)
            assert(totalBalance >= amount, message: "Insufficient balance. You have \(totalBalance) but trying to withdraw \(amount)")

            // DUST PREVENTION: If remaining balance after withdrawal would be below dust threshold,
            // treat this as a full withdrawal to prevent dust from being left behind.
            // This also handles rounding errors where user's calculated balance differs slightly
            // from actual yield source availability.
            // Using 1/10 of minimumDeposit as threshold to only catch true rounding dust,
            // not meaningful partial balances.
            let dustThreshold = self.config.minimumDeposit / 10.0
            let remainingBalance = totalBalance - amount
            let isFullWithdrawal = remainingBalance < dustThreshold

            // For full withdrawals, request the full balance (may be adjusted by yield source availability)
            var withdrawAmount = isFullWithdrawal ? totalBalance : amount

            // Check if yield source has sufficient liquidity
            let yieldAvailable = self.config.yieldConnector.minimumAvailable()

            // For full withdrawals with minor rounding mismatch, use available amount
            if isFullWithdrawal && yieldAvailable < withdrawAmount && yieldAvailable > 0.0 {
                withdrawAmount = yieldAvailable
            }

            // Handle insufficient liquidity in yield source
            if yieldAvailable < withdrawAmount {
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
                emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: 0.0, ownerAddress: ownerAddress)
                return <- DeFiActionsUtils.getEmptyVault(self.config.assetType)
            }
            
            // Attempt withdrawal from yield source
            let withdrawn <- self.config.yieldConnector.withdrawAvailable(maxAmount: withdrawAmount)
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
                
                emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: 0.0, ownerAddress: ownerAddress)
                return <- withdrawn
            }
            
            // Successful withdrawal - reset failure counter
            if self.emergencyState == PoolEmergencyState.Normal {
                self.consecutiveWithdrawFailures = 0
            }
            
            let now = getCurrentBlock().timestamp
            
            // Get current shares BEFORE the withdrawal for TWAB calculation
            let oldShares = self.shareTracker.getUserShares(receiverID: receiverID)
            
            // Burn shares proportional to withdrawal
            let actualBurned = self.shareTracker.withdraw(
                receiverID: receiverID,
                amount: actualWithdrawn,
                dustThreshold: dustThreshold
            )
            
            // Get new shares AFTER the withdrawal
            let newShares = self.shareTracker.getUserShares(receiverID: receiverID)
            
            // Update TWAB in the active round (if exists)
            if let round = &self.activeRound as &Round? {
                round.recordShareChange(
                    receiverID: receiverID,
                    oldShares: oldShares,
                    newShares: newShares,
                    atTime: now 
                )
            }

            // Update pool total
            self.allocatedRewards = self.allocatedRewards - actualWithdrawn
            
            // If user has withdrawn to 0 shares, unregister them
            // BUT NOT if a draw is in progress - unregistering during batch processing
            // would corrupt indices (swap-and-pop). Ghost users with 0 shares get 0 weight.
            // They can be cleaned up via admin cleanupStaleEntries() after the draw.
            if newShares == 0.0 && self.pendingSelectionData == nil {
                // Handle sponsors vs regular receivers differently
                if self.sponsorReceivers[receiverID] == true {
                    // Clean up sponsor mapping
                    let _ = self.sponsorReceivers.remove(key: receiverID)
                } else {
                    // Unregister regular receiver from prize draws
                    self.unregisterReceiver(receiverID: receiverID)
                }
            }
            
            emit Withdrawn(poolID: self.poolID, receiverID: receiverID, requestedAmount: amount, actualAmount: actualWithdrawn, ownerAddress: ownerAddress)
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
        /// ALLOCATED FUNDS (see getTotalAllocatedFunds()):
        /// allocatedRewards + allocatedPrizeYield + allocatedProtocolFee
        /// This sum must always equal the yield source balance after sync.
        /// 
        /// EXCESS (yieldBalance > allocatedFunds):
        /// 1. Calculate excess amount
        /// 2. Apply distribution strategy (rewards/prize/protocolFee split)
        /// 3. Accrue rewards yield to share price (increases allocatedRewards)
        /// 4. Add prize yield to allocatedPrizeYield
        /// 5. Add protocol fee to allocatedProtocolFee
        /// 
        /// DEFICIT (yieldBalance < allocatedFunds):
        /// 1. Calculate deficit amount
        /// 2. Distribute proportionally across all allocations
        /// 3. Reduce allocatedProtocolFee first (protocol absorbs loss first)
        /// 4. Reduce allocatedPrizeYield second
        /// 5. Reduce rewards (share price) last - protecting user principal
        /// 
        /// Called automatically during deposits and withdrawals.
        /// Can also be called manually by admin.
        access(contract) fun syncWithYieldSource() {
            let yieldBalance = self.config.yieldConnector.minimumAvailable()
            let allocatedFunds = self.getTotalAllocatedFunds()
            
            // Calculate absolute difference
            let difference: UFix64 = yieldBalance > allocatedFunds 
                ? yieldBalance - allocatedFunds 
                : allocatedFunds - yieldBalance
            
            // Skip sync for amounts below threshold to avoid precision loss.
            // Small discrepancies accumulate in the yield source until they exceed threshold.
            if difference < PrizeLinkedAccounts.MINIMUM_DISTRIBUTION_THRESHOLD {
                return
            }
            
            // === EXCESS: Apply gains ===
            if yieldBalance > allocatedFunds {
                self.applyExcess(amount: difference)
                return
            }
            
            // === DEFICIT: Apply shortfall ===
            if yieldBalance < allocatedFunds {
                self.applyDeficit(amount: difference)
                return
            }
            
            // === BALANCED: Nothing to do ===
        }
        
        /// Deposits a vault's full balance to the yield source.
        /// Asserts the entire amount was accepted; reverts if any funds are left over.
        /// Destroys the vault after successful deposit.
        ///
        /// @param vault - The vault to deposit (will be destroyed)
        access(self) fun depositToYieldSourceFull(_ vault: @{FungibleToken.Vault}) {
            let beforeBalance = vault.balance
            self.config.yieldConnector.depositCapacity(from: &vault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            let deposited = beforeBalance - vault.balance
            assert(vault.balance == 0.0, message: "Yield sink could not accept full deposit. Deposited: \(deposited), leftover: \(vault.balance)")
            destroy vault
        }

        /// Applies excess funds (appreciation) according to the distribution strategy.
        ///
        /// All portions stay in the yield source and are tracked via pending variables.
        /// Actual transfers happen at draw time (prize yield → prize pool, protocol → recipient/vault).
        ///
        /// @param amount - Total excess amount to distribute
        access(self) fun applyExcess(amount: UFix64) {
            if amount == 0.0 {
                return
            }
            
            // Note: Threshold check is done in syncWithYieldSource() before calling this function
            
            // Apply distribution strategy
            let plan = self.config.distributionStrategy.calculateDistribution(totalAmount: amount)
            
            var rewardsDust: UFix64 = 0.0
            
            // Process rewards portion - increases share price for all users
            if plan.rewardsAmount > 0.0 {
                // Accrue returns actual amount after virtual share dust
                let actualRewards = self.shareTracker.accrueYield(amount: plan.rewardsAmount)
                rewardsDust = plan.rewardsAmount - actualRewards
                self.allocatedRewards = self.allocatedRewards + actualRewards
                emit RewardsYieldAccrued(poolID: self.poolID, amount: actualRewards)
                
                if rewardsDust > 0.0 {
                    emit RewardsRoundingDustToProtocolFee(poolID: self.poolID, amount: rewardsDust)
                }
            }
            
            // Process prize portion - stays in yield source until draw
            if plan.prizeAmount > 0.0 {
                self.allocatedPrizeYield = self.allocatedPrizeYield + plan.prizeAmount
                emit PrizePoolFunded(
                    poolID: self.poolID,
                    amount: plan.prizeAmount,
                    source: "yield_pending"
                )
            }
            
            // Process protocol portion + rewards dust - stays in yield source until draw
            let totalProtocolAmount = plan.protocolFeeAmount + rewardsDust
            if totalProtocolAmount > 0.0 {
                self.allocatedProtocolFee = self.allocatedProtocolFee + totalProtocolAmount
                emit ProtocolFeeFunded(
                    poolID: self.poolID,
                    amount: totalProtocolAmount,
                    source: "yield_pending"
                )
            }
            
            emit RewardsProcessed(
                poolID: self.poolID,
                totalAmount: amount,
                rewardsAmount: plan.rewardsAmount - rewardsDust,
                prizeAmount: plan.prizeAmount
            )
        }
        
        /// Applies a deficit (depreciation) from the yield source across the pool.
        ///
        /// Uses a deterministic waterfall that protects user funds (rewards) by
        /// exhausting protocol fee (protocol, prize) first. This is INDEPENDENT
        /// of the distribution strategy to ensure consistent loss handling even after
        /// strategy changes.
        ///
        /// WATERFALL ORDER (protect user principal):
        /// 1. Protocol absorbs first (drain completely if needed)
        /// 2. Prize absorbs second (drain completely if needed)
        /// 3. Rewards absorbs last (share price decrease affects all users)
        ///
        /// If all three are exhausted but deficit remains, an InsolvencyDetected
        /// event is emitted to alert administrators.
        ///
        /// @param amount - Total deficit to absorb
        access(self) fun applyDeficit(amount: UFix64) {
            if amount == 0.0 {
                return
            }

            var remainingDeficit = amount

            // === STEP 1: Protocol absorbs first (protocol fund) ===
            var absorbedByProtocolFee: UFix64 = 0.0
            if remainingDeficit > 0.0 && self.allocatedProtocolFee > 0.0 {
                absorbedByProtocolFee = remainingDeficit > self.allocatedProtocolFee
                    ? self.allocatedProtocolFee
                    : remainingDeficit
                self.allocatedProtocolFee = self.allocatedProtocolFee - absorbedByProtocolFee
                remainingDeficit = remainingDeficit - absorbedByProtocolFee
            }

            // === STEP 2: Prize absorbs second (protocol fund) ===
            var absorbedByPrize: UFix64 = 0.0
            if remainingDeficit > 0.0 && self.allocatedPrizeYield > 0.0 {
                absorbedByPrize = remainingDeficit > self.allocatedPrizeYield
                    ? self.allocatedPrizeYield
                    : remainingDeficit
                self.allocatedPrizeYield = self.allocatedPrizeYield - absorbedByPrize
                remainingDeficit = remainingDeficit - absorbedByPrize
            }

            // === STEP 3: Rewards absorbs last (user funds) ===
            var absorbedByRewards: UFix64 = 0.0
            if remainingDeficit > 0.0 {
                absorbedByRewards = self.shareTracker.decreaseTotalAssets(amount: remainingDeficit)
                self.allocatedRewards = self.allocatedRewards - absorbedByRewards
                remainingDeficit = remainingDeficit - absorbedByRewards
            }

            // === Check for insolvency ===
            if remainingDeficit > 0.0 {
                emit InsolvencyDetected(
                    poolID: self.poolID,
                    unreconciledAmount: remainingDeficit
                )
            }

            emit DeficitApplied(
                poolID: self.poolID,
                totalDeficit: amount,
                absorbedByProtocolFee: absorbedByProtocolFee,
                absorbedByPrize: absorbedByPrize,
                absorbedByRewards: absorbedByRewards
            )
        }
        
        // ============================================================
        // LOTTERY DRAW OPERATIONS
        // ============================================================
        
        /// Starts a prize draw (Phase 1 of 3 - Batched Draw Process).
        /// 
        /// FLOW:
        /// 1. Validate state (Normal, no active draw, round has ended)
        /// 2. Set actualEndTime on activeRound (marks it for finalization)
        /// 3. Initialize batch capture state with receiver snapshot
        /// 4. Materialize yield and request randomness
        /// 5. Emit DrawBatchStarted and randomness events
        ///
        /// NEXT STEPS:
        /// - Call processDrawBatch() repeatedly to capture TWAB weights
        /// 
        access(contract) fun startDraw() {
            pre {
                self.emergencyState == PoolEmergencyState.Normal: "Draws disabled - pool state: \(self.emergencyState.rawValue)"
                self.pendingDrawReceipt == nil: "Draw already in progress"
                self.activeRound != nil: "Pool is in intermission - call startNextRound first"
            }

            // Validate round has ended (this replaces the old draw interval check)
            assert(self.canDrawNow(), message: "Round has not ended yet")

            // Final health check before draw
            if self.checkAndAutoTriggerEmergency() {
                panic("Emergency mode auto-triggered - cannot start draw")
            }

            let now = getCurrentBlock().timestamp

            // Get the current round's info
            // Reference is safe - we validated activeRound != nil in precondition
            let activeRoundRef = (&self.activeRound as &Round?)!
            let endedRoundID = activeRoundRef.getRoundID()

            // Set the actual end time on the round being finalized
            // This is the moment we're finalizing - used for TWAB calculations
            activeRoundRef.setActualEndTime(now)

            // Create selection data resource for batch processing
            // Snapshot the current receiver count - only these users will be processed
            // New deposits during batch processing won't extend the batch (prevents DoS)
            self.pendingSelectionData <-! create BatchSelectionData(
                snapshotCount: self.registeredReceiverList.length
            )

            // Update last draw timestamp (draw initiated, even though batch processing pending)
            self.lastDrawTimestamp = now
            
            // Materialize pending prize funds from yield source
            if self.allocatedPrizeYield > 0.0 {
                let prizeVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: self.allocatedPrizeYield)
                let actualWithdrawn = prizeVault.balance
                self.prizeDistributor.fundPrizePool(vault: <- prizeVault)
                self.allocatedPrizeYield = self.allocatedPrizeYield - actualWithdrawn
            }
            
            // Materialize pending protocol fee from yield source
            if self.allocatedProtocolFee > 0.0 {
                let protocolVault <- self.config.yieldConnector.withdrawAvailable(maxAmount: self.allocatedProtocolFee)
                let actualWithdrawn = protocolVault.balance
                self.allocatedProtocolFee = self.allocatedProtocolFee - actualWithdrawn
                
                // Forward to recipient if configured, otherwise store in unclaimed vault
                if let cap = self.protocolFeeRecipientCap {
                    if let recipientRef = cap.borrow() {
                        let forwardedAmount = protocolVault.balance
                        recipientRef.deposit(from: <- protocolVault)
                        self.totalProtocolFeeForwarded = self.totalProtocolFeeForwarded + forwardedAmount
                        emit ProtocolFeeForwarded(
                            poolID: self.poolID,
                            amount: forwardedAmount,
                            recipient: cap.address
                        )
                    } else {
                        // Recipient capability invalid - store in unclaimed vault
                        self.unclaimedProtocolFeeVault.deposit(from: <- protocolVault)
                    }
                } else {
                    // No recipient configured - store in unclaimed vault for admin withdrawal
                    self.unclaimedProtocolFeeVault.deposit(from: <- protocolVault)
                }
            }
            
            let prizeAmount = self.prizeDistributor.getPrizePoolBalance()
            assert(prizeAmount > 0.0, message: "No prize pool funds")
            
            // Request randomness now - will be fulfilled in completeDraw() after batch processing
            let randomRequest <- self.randomConsumer.requestRandomness()
            let receipt <- create PrizeDrawReceipt(
                prizeAmount: prizeAmount,
                request: <- randomRequest
            )
            
            let commitBlock = receipt.getRequestBlock() ?? 0
            self.pendingDrawReceipt <-! receipt

            // Emit draw started event (weights will be captured via batch processing)
            emit DrawBatchStarted(
                poolID: self.poolID,
                endedRoundID: endedRoundID,
                newRoundID: 0,  // No new round created yet - pool enters intermission
                totalReceivers: self.registeredReceiverList.length
            )
            
            // Emit randomness committed event
            emit DrawRandomnessRequested(
                poolID: self.poolID,
                totalWeight: 0.0,  // Not known yet - weights captured during batch processing
                prizeAmount: prizeAmount,
                commitBlock: commitBlock
            )
        }
        
        /// Processes a batch of receivers for weight capture (Phase 2 of 3).
        /// 
        /// Call this repeatedly until isDrawBatchComplete() returns true.
        /// Iterates directly over registeredReceiverList using selection data cursor.
        /// 
        /// FLOW:
        /// 1. Get current shares for each receiver in batch
        /// 2. Calculate TWAB from activeRound (which has actualEndTime set)
        /// 3. Add bonus weights (scaled by round duration)
        /// 4. Build cumulative weight sums in pendingSelectionData (for binary search)
        /// 
        /// @param limit - Maximum receivers to process this batch
        /// @return Number of receivers remaining to process
        access(contract) fun processDrawBatch(limit: Int): Int {
            pre {
                limit >= 0: "Batch limit cannot be negative"
                self.activeRound != nil: "No draw in progress"
                self.pendingDrawReceipt != nil: "No draw receipt - call startDraw first"
                self.pendingSelectionData != nil: "No selection data"
                !self.isBatchComplete(): "Batch processing already complete"
            }

            // Get reference to selection data
            let selectionDataRef = (&self.pendingSelectionData as &BatchSelectionData?)!
            let selectionData = selectionDataRef

            let startCursor = selectionData.getCursor()

            // Get the active round reference
            let activeRoundRef = (&self.activeRound as &Round?)!
            
            // Get the actual end time set by startDraw() - this is when we finalized the round
            // This must exist since startDraw() sets it - if nil, the state is corrupted
            let roundEndTime = activeRoundRef.getActualEndTime() 
                ?? panic("Corrupted state: actualEndTime not set. startDraw() must be called first.")
            
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
                let shares = self.shareTracker.getUserShares(receiverID: receiverID)
                
                // Finalize TWAB using actual round end time
                // Returns NORMALIZED weight (≈ average shares)
                let twabStake = activeRoundRef.finalizeTWAB(
                    receiverID: receiverID, 
                    currentShares: shares,
                    roundEndTime: roundEndTime
                )
                
                let bonusWeight = self.getBonusWeight(receiverID: receiverID)
                
                let totalWeight = twabStake + bonusWeight
                
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
            
            // Runtime guardrail: emit warning if totalWeight exceeds threshold
            // With normalized TWAB this should never happen, but provides extra safety
            let currentTotalWeight = selectionData.getTotalWeight()
            if currentTotalWeight > PrizeLinkedAccounts.WEIGHT_WARNING_THRESHOLD {
                let percentOfMax = currentTotalWeight / PrizeLinkedAccounts.UFIX64_MAX * 100.0
                emit WeightWarningThresholdExceeded(
                    poolID: self.poolID,
                    totalWeight: currentTotalWeight,
                    warningThreshold: PrizeLinkedAccounts.WEIGHT_WARNING_THRESHOLD,
                    percentOfMax: percentOfMax
                )
            }
            
            emit DrawBatchProcessed(
                poolID: self.poolID,
                processed: processed,
                remaining: remaining
            )
            
            return remaining
        }
        
        /// Completes a prize draw (Phase 3 of 3).
        /// 
        /// PREREQUISITES:
        /// - startDraw() must have been called (randomness requested, yield materialized)
        /// - processDrawBatch() must have been called until batch is complete
        /// - At least 1 block must have passed since startDraw() for randomness fulfillment
        /// 
        /// FLOW:
        /// 1. Consume PrizeDrawReceipt (created by startDraw)
        /// 2. Fulfill randomness request (secure on-chain random from previous block)
        /// 3. Apply winner selection strategy with captured weights
        /// 4. For each winner:
        ///    a. Withdraw prize from prize pool
        ///    b. Auto-compound prize into winner's deposit (mints shares + updates TWAB)
        ///    c. Re-deposit prize to yield source (continues earning)
        ///    d. Award any NFT prizes (stored for claiming)
        /// 5. Record winners in tracker (if configured)
        /// 6. Emit PrizesAwarded event
        /// 7. Destroy activeRound (cleanup, pool enters intermission)
        /// 
        /// TWAB: Prize deposits accumulate TWAB in the active round,
        /// giving winners credit for their new shares going forward.
        /// 
        /// IMPORTANT: Prizes are AUTO-COMPOUNDED into deposits, not transferred.
        /// Winners can withdraw their increased balance at any time.
        access(contract) fun completeDraw() {
            pre {
                self.pendingDrawReceipt != nil: "No draw in progress - call startDraw first"
                self.pendingSelectionData != nil: "No selection data"
                self.isBatchComplete(): "Batch processing not complete - call processDrawBatch until complete"
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
                    winnerAddresses: [],
                    amounts: [],
                    round: self.prizeDistributor.getPrizeRound()
                )
                // Still need to clean up the active round
                // Store the completed round ID before destroying for intermission state queries
                let usedRound <- self.activeRound <- nil
                let completedRoundID = usedRound?.getRoundID() ?? 0
                self.lastCompletedRoundID = completedRoundID
                destroy usedRound
                
                // Pool is now in intermission - emit event
                emit IntermissionStarted(
                    poolID: self.poolID,
                    completedRoundID: completedRoundID,
                    prizePoolBalance: self.prizeDistributor.getPrizePoolBalance()
                )
                return
            }
            
            // Validate parallel arrays are consistent
            assert(distributedWinners.length == prizeAmounts.length, message: "Winners and prize amounts must match")
            assert(distributedWinners.length == nftIDsPerWinner.length, message: "Winners and NFT IDs must match")
            
            // Increment draw round
            let currentRound = self.prizeDistributor.getPrizeRound() + 1
            self.prizeDistributor.setPrizeRound(round: currentRound)
            var totalAwarded: UFix64 = 0.0
            
            // Process each winner
            for i in InclusiveRange(0, distributedWinners.length - 1) {
                let winnerID = distributedWinners[i]
                let prizeAmount = prizeAmounts[i]
                let nftIDsForWinner = nftIDsPerWinner[i]
                
                // Withdraw prize from prize pool
                let prizeVault <- self.prizeDistributor.withdrawPrize(
                    amount: prizeAmount,
                    yieldSource: nil
                )
                
                // Get current shares BEFORE the prize deposit for TWAB calculation
                let oldShares = self.shareTracker.getUserShares(receiverID: winnerID)
                
                // AUTO-COMPOUND: Add prize to winner's deposit (mints shares)
                let newSharesMinted = self.shareTracker.deposit(receiverID: winnerID, amount: prizeAmount)
                let newShares = oldShares + newSharesMinted
                
                // Update TWAB in active round if one exists (prize deposits accumulate TWAB like regular deposits)
                // Note: Pool is in intermission during completeDraw (activeRound == nil)
                // Prize amounts are added to shares but no TWAB is recorded until next round starts
                if let round = &self.activeRound as &Round? {
                    let now = getCurrentBlock().timestamp
                    round.recordShareChange(
                        receiverID: winnerID,
                        oldShares: oldShares,
                        newShares: newShares,
                        atTime: now
                    )
                }
                
                // Update pool total
                self.allocatedRewards = self.allocatedRewards + prizeAmount
                
                // Re-deposit prize to yield source (continues earning)
                self.depositToYieldSourceFull(<- prizeVault)

                // Track lifetime prize winnings
                let totalPrizes = self.receiverTotalEarnedPrizes[winnerID] ?? 0.0
                self.receiverTotalEarnedPrizes[winnerID] = totalPrizes + prizeAmount
                
                // Process NFT prizes for this winner
                for nftID in nftIDsForWinner {
                    // Verify NFT is still available - O(1) dictionary lookup
                    // (might have been withdrawn by admin during draw)
                    if self.prizeDistributor.borrowNFTPrize(nftID: nftID) == nil {
                        continue
                    }
                    
                    // Move NFT to pending claims for winner to pick up
                    let nft <- self.prizeDistributor.withdrawNFTPrize(nftID: nftID)
                    let nftType = nft.getType().identifier
                    self.prizeDistributor.storePendingNFT(receiverID: winnerID, nft: <- nft)
                    
                    emit NFTPrizeStored(
                        poolID: self.poolID,
                        receiverID: winnerID,
                        nftID: nftID,
                        nftType: nftType,
                        reason: "Prize win - round \(currentRound)"
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
            
            // Build winner addresses array from capabilities
            let winnerAddresses: [Address?] = []
            for winnerID in distributedWinners {
                winnerAddresses.append(self.getReceiverOwnerAddress(receiverID: winnerID))
            }
            
            emit PrizesAwarded(
                poolID: self.poolID,
                winners: distributedWinners,
                winnerAddresses: winnerAddresses,
                amounts: prizeAmounts,
                round: currentRound
            )
            
            // Destroy the active round - its TWAB data has been used
            // Store the completed round ID before destroying for intermission state queries
            let usedRound <- self.activeRound <- nil
            let completedRoundID = usedRound?.getRoundID() ?? 0
            self.lastCompletedRoundID = completedRoundID
            destroy usedRound
            
            // Pool is now in intermission - emit event
            emit IntermissionStarted(
                poolID: self.poolID,
                completedRoundID: completedRoundID,
                prizePoolBalance: self.prizeDistributor.getPrizePoolBalance()
            )
        }
        
        /// Starts a new round, exiting intermission (Phase 5 - optional, for explicit round control).
        /// 
        /// Creates a new active round with the configured draw interval duration.
        /// This must be called after completeDraw() to begin the next round.
        /// 
        /// PRECONDITIONS:
        /// - Pool must be in intermission (activeRound == nil)
        /// - No pending draw receipt (randomness request completed)
        ///
        /// EMITS: IntermissionEnded
        access(contract) fun startNextRound() {
            pre {
                self.activeRound == nil: "Pool is not in intermission"
                self.pendingDrawReceipt == nil: "Pending randomness request not completed"
            }

            let now = getCurrentBlock().timestamp
            let newRoundID = self.lastCompletedRoundID + 1
            let duration = self.config.drawIntervalSeconds

            self.activeRound <-! create Round(
                roundID: newRoundID,
                startTime: now,
                targetEndTime: now + duration
            )

            emit IntermissionEnded(
                poolID: self.poolID,
                newRoundID: newRoundID,
                roundDuration: duration
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
        
        /// Updates the draw interval for FUTURE rounds only.
        /// Does not affect the current active round at all.
        /// 
        /// @param interval - New interval in seconds
        access(contract) fun setDrawIntervalSecondsForFutureOnly(interval: UFix64) {
            // Only update pool config - current round is not affected
            self.config.setDrawIntervalSeconds(interval: interval)
        }
        
        /// Returns the current active round's duration.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getActiveRoundDuration(): UFix64 {
            return self.activeRound?.getDuration() ?? 0.0
        }

        /// Returns the current active round's ID.
        /// Returns 0 if in intermission (no active round).
        access(all) view fun getActiveRoundID(): UInt64 {
            return self.activeRound?.getRoundID() ?? 0
        }

        /// Returns the current active round's target end time.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getCurrentRoundTargetEndTime(): UFix64 {
            return self.activeRound?.getTargetEndTime() ?? 0.0
        }

        /// Updates the current round's target end time.
        /// Can only be called before startDraw() is called on this round.
        /// @param newTarget - New target end time (must be after round start time)
        access(contract) fun setCurrentRoundTargetEndTime(newTarget: UFix64) {
            pre {
                self.activeRound != nil: "No active round - pool is in intermission"
            }
            let roundRef = (&self.activeRound as &Round?)!
            roundRef.setTargetEndTime(newTarget: newTarget)
        }

        /// Updates the minimum deposit amount.
        /// @param minimum - New minimum deposit
        access(contract) fun setMinimumDeposit(minimum: UFix64) {
            self.config.setMinimumDeposit(minimum: minimum)
        }
        
        // ============================================================
        // BONUS WEIGHT MANAGEMENT
        // ============================================================
        
        /// Sets or replaces a user's bonus prize weight.
        /// @param receiverID - User's receiver ID
        /// @param bonusWeight - Weight to assign (replaces existing)
        /// @param reason - Reason for bonus
        /// @param adminUUID - Admin performing the action
        access(contract) fun setBonusWeight(receiverID: UInt64, bonusWeight: UFix64, reason: String, adminUUID: UInt64) {
            let timestamp = getCurrentBlock().timestamp
            self.receiverBonusWeights[receiverID] = bonusWeight
            
            emit BonusPrizeWeightSet(
                poolID: self.poolID,
                receiverID: receiverID,
                bonusWeight: bonusWeight,
                reason: reason,
                adminUUID: adminUUID,
                timestamp: timestamp
            )
        }
        
        /// Adds weight to a user's existing bonus.
        /// @param receiverID - User's receiver ID
        /// @param additionalWeight - Weight to add
        /// @param reason - Reason for addition (emitted in event)
        /// @param adminUUID - Admin performing the action
        access(contract) fun addBonusWeight(receiverID: UInt64, additionalWeight: UFix64, reason: String, adminUUID: UInt64) {
            let timestamp = getCurrentBlock().timestamp
            let currentBonus = self.receiverBonusWeights[receiverID] ?? 0.0
            let newTotalBonus = currentBonus + additionalWeight
            
            self.receiverBonusWeights[receiverID] = newTotalBonus
            
            emit BonusPrizeWeightAdded(
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
            let previousBonus = self.receiverBonusWeights[receiverID] ?? 0.0
            
            let _ = self.receiverBonusWeights.remove(key: receiverID)
            
            emit BonusPrizeWeightRemoved(
                poolID: self.poolID,
                receiverID: receiverID,
                previousBonus: previousBonus,
                adminUUID: adminUUID,
                timestamp: timestamp
            )
        }
        
        /// Returns a user's current bonus weight (equivalent token deposit for full round).
        /// @param receiverID - User's receiver ID
        access(all) view fun getBonusWeight(receiverID: UInt64): UFix64 {
            return self.receiverBonusWeights[receiverID] ?? 0.0
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
            self.prizeDistributor.depositNFTPrize(nft: <- nft)
        }
        
        /// Withdraws an available NFT prize. Called by Admin.
        /// @param nftID - UUID of NFT to withdraw
        /// @return The withdrawn NFT
        access(contract) fun withdrawNFTPrize(nftID: UInt64): @{NonFungibleToken.NFT} {
            return <- self.prizeDistributor.withdrawNFTPrize(nftID: nftID)
        }
        
        /// Returns UUIDs of all available NFT prizes.
        access(all) view fun getAvailableNFTPrizeIDs(): [UInt64] {
            return self.prizeDistributor.getAvailableNFTPrizeIDs()
        }
        
        /// Borrows a reference to an available NFT prize.
        /// @param nftID - UUID of NFT
        /// @return Reference to NFT, or nil if not found
        access(all) view fun borrowAvailableNFTPrize(nftID: UInt64): &{NonFungibleToken.NFT}? {
            return self.prizeDistributor.borrowNFTPrize(nftID: nftID)
        }
        
        /// Returns count of pending NFT claims for a user.
        /// @param receiverID - User's receiver ID
        access(all) view fun getPendingNFTCount(receiverID: UInt64): Int {
            return self.prizeDistributor.getPendingNFTCount(receiverID: receiverID)
        }
        
        /// Returns UUIDs of pending NFT claims for a user.
        /// @param receiverID - User's receiver ID
        access(all) fun getPendingNFTIDs(receiverID: UInt64): [UInt64] {
            return self.prizeDistributor.getPendingNFTIDs(receiverID: receiverID)
        }
        
        /// Claims a pending NFT prize for a user.
        /// Called by PoolPositionCollection.
        /// @param receiverID - User's receiver ID
        /// @param nftIndex - Index in pending claims array
        /// @return The claimed NFT
        access(contract) fun claimPendingNFT(receiverID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            let nft <- self.prizeDistributor.claimPendingNFT(receiverID: receiverID, nftIndex: nftIndex)
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
        /// Returns false if in intermission (no active round) - must call startNextRound first.
        access(all) view fun canDrawNow(): Bool {
            return self.activeRound?.hasEnded() ?? false
        }
        
        /// Returns total withdrawable balance for a receiver.
        /// This is the receiver's shares × current share price.
        access(all) view fun getReceiverTotalBalance(receiverID: UInt64): UFix64 {
            return self.shareTracker.getUserAssetValue(receiverID: receiverID)
        }
        
        /// Returns lifetime total prizes earned by this receiver.
        /// This is a cumulative counter that increases when prizes are won.
        access(all) view fun getReceiverTotalEarnedPrizes(receiverID: UInt64): UFix64 {
            return self.receiverTotalEarnedPrizes[receiverID] ?? 0.0
        }
        
        access(all) view fun getUserRewardsShares(receiverID: UInt64): UFix64 {
            return self.shareTracker.getUserShares(receiverID: receiverID)
        }
        
        access(all) view fun getTotalRewardsShares(): UFix64 {
            return self.shareTracker.getTotalShares()
        }
        
        access(all) view fun getTotalRewardsAssets(): UFix64 {
            return self.shareTracker.getTotalAssets()
        }
        
        access(all) view fun getRewardsSharePrice(): UFix64 {
            return self.shareTracker.getSharePrice()
        }
        
        /// Returns the user's current TWAB for the active round.
        /// @param receiverID - User's receiver ID
        /// @return Current TWAB (accumulated + pending up to now)
        access(all) view fun getUserTimeWeightedShares(receiverID: UInt64): UFix64 {
            if let round = &self.activeRound as &Round? {
                let shares = self.shareTracker.getUserShares(receiverID: receiverID)
                let now = getCurrentBlock().timestamp
                return round.getCurrentTWAB(receiverID: receiverID, currentShares: shares, atTime: now)
            }
            return 0.0
        }

        /// Returns the current round ID.
        /// During intermission, returns the ID of the last completed round.
        access(all) view fun getCurrentRoundID(): UInt64 {
            if let round = &self.activeRound as &Round? {
                return round.getRoundID()
            }
            // In intermission - return last completed round ID
            return self.lastCompletedRoundID
        }
        
        /// Returns the current round start time.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getRoundStartTime(): UFix64 {
            return self.activeRound?.getStartTime() ?? 0.0
        }

        /// Returns the current round end time.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getRoundEndTime(): UFix64 {
            return self.activeRound?.getEndTime() ?? 0.0
        }

        /// Returns the current round duration.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getRoundDuration(): UFix64 {
            return self.activeRound?.getDuration() ?? 0.0
        }

        /// Returns elapsed time since round started.
        /// Returns 0.0 if in intermission (no active round).
        access(all) view fun getRoundElapsedTime(): UFix64 {
            if let round = &self.activeRound as &Round? {
                let startTime = round.getStartTime()
                let now = getCurrentBlock().timestamp
                if now > startTime {
                    return now - startTime
                }
            }
            return 0.0
        }

        /// Returns whether the active round has ended (gap period).
        /// Returns true if in intermission (no active round).
        access(all) view fun isRoundEnded(): Bool {
            return self.activeRound?.hasEnded() ?? true
        }

        // ============================================================
        // POOL STATE MACHINE
        // ============================================================
        //
        // State 1: ROUND_ACTIVE    - Round in progress, timer hasn't expired
        // State 2: AWAITING_DRAW   - Round ended, waiting for admin to start draw
        // State 3: DRAW_PROCESSING - Draw ceremony in progress (phases 1-3)
        // State 4: INTERMISSION    - Draw complete, waiting for next round to start
        //
        // Transition: ROUND_ACTIVE → AWAITING_DRAW → DRAW_PROCESSING → INTERMISSION → ROUND_ACTIVE
        // ============================================================

        /// STATE 1: Returns whether a round is actively in progress (timer hasn't expired).
        /// Use this to show countdown timers and "round in progress" UI.
        access(all) view fun isRoundActive(): Bool {
            if let round = &self.activeRound as &Round? {
                return !round.hasEnded()
            }
            return false
        }

        /// STATE 2: Returns whether the round has ended and is waiting for draw to start.
        /// This is the window where an admin needs to call startDraw().
        /// Use this to show "Draw available" or "Waiting for draw" UI.
        access(all) view fun isAwaitingDraw(): Bool {
            if let round = &self.activeRound as &Round? {
                return round.hasEnded() && self.pendingDrawReceipt == nil
            }
            return false
        }

        /// STATE 3: Returns whether a draw is being processed.
        /// This covers all draw phases: batch processing and winner selection.
        /// Use this to show "Draw in progress" with batch progress UI.
        access(all) view fun isDrawInProgress(): Bool {
            return self.pendingDrawReceipt != nil
        }

        /// STATE 4: Returns whether the pool is in true intermission.
        /// Intermission = draw completed, no active round, waiting for startNextRound().
        access(all) view fun isInIntermission(): Bool {
            return self.activeRound == nil && self.pendingDrawReceipt == nil
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
        
        /// Returns whether batch processing is in progress (after startDraw, before batch complete).
        access(all) view fun isDrawBatchInProgress(): Bool {
            return self.pendingDrawReceipt != nil && self.pendingSelectionData != nil && !self.isBatchComplete()
        }
        
        /// Returns whether batch processing is complete and ready for completeDraw.
        /// Batch processing must finish before completeDraw can be called.
        access(all) view fun isDrawBatchComplete(): Bool {
            return self.pendingSelectionData != nil && self.isBatchComplete() && self.pendingDrawReceipt != nil
        }
        
        /// Returns whether the draw is ready to complete.
        /// Requires: randomness requested (in startDraw) AND batch processing complete.
        access(all) view fun isReadyForDrawCompletion(): Bool {
            return self.pendingDrawReceipt != nil && self.isBatchComplete()
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
            return self.shareTracker.convertToShares(amount)
        }
        
        /// Preview how many assets a number of shares is worth (ERC-4626 style)
        access(all) view fun previewRedeem(shares: UFix64): UFix64 {
            return self.shareTracker.convertToAssets(shares)
        }
        
        access(all) view fun getUserRewardsValue(receiverID: UInt64): UFix64 {
            return self.shareTracker.getUserAssetValue(receiverID: receiverID)
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
        
        /// Returns whether a receiver is a sponsor (prize-ineligible).
        /// @param receiverID - UUID of the receiver to check
        /// @return true if the receiver is a sponsor, false otherwise
        access(all) view fun isSponsor(receiverID: UInt64): Bool {
            return self.sponsorReceivers[receiverID] ?? false
        }
        
        /// Returns the total number of sponsors in this pool.
        access(all) view fun getSponsorCount(): Int {
            return self.sponsorReceivers.keys.length
        }
        
        access(all) view fun getConfig(): PoolConfig {
            return self.config
        }
        
        access(all) view fun getTotalRewardsDistributed(): UFix64 {
            return self.shareTracker.getTotalDistributed()
        }
        
        access(all) fun getAvailableYieldRewards(): UFix64 {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let available = yieldSource.minimumAvailable()
            // Exclude already-allocated funds (same logic as syncWithYieldSource)
            let allocatedFunds = self.getTotalAllocatedFunds()
            if available > allocatedFunds {
                return available - allocatedFunds
            }
            return 0.0
        }
        
        /// Returns true if internal accounting differs from yield source balance.
        /// Handles both excess (gains) and deficit (losses).
        /// This is used to determine if syncWithYieldSource() needs to be called.
        access(all) fun needsSync(): Bool {
            let yieldSource = &self.config.yieldConnector as &{DeFiActions.Source}
            let yieldBalance = yieldSource.minimumAvailable()
            return yieldBalance != self.getTotalAllocatedFunds()
        }
        
        // ============================================================
        // YIELD ALLOCATION GETTERS
        // ============================================================
        
        /// Returns total funds allocated across all buckets (rewards + prize + protocolFee).
        /// This sum should always equal the yield source balance after sync.
        access(all) view fun getTotalAllocatedFunds(): UFix64 {
            return self.allocatedRewards + self.allocatedPrizeYield + self.allocatedProtocolFee
        }
        
        /// Returns the allocated rewards amount (user portion of yield source).
        access(all) view fun getAllocatedRewards(): UFix64 {
            return self.allocatedRewards
        }
        
        /// Returns the allocated prize yield (awaiting transfer to prize pool).
        access(all) view fun getAllocatedPrizeYield(): UFix64 {
            return self.allocatedPrizeYield
        }

        /// Returns the allocated protocol fee (awaiting transfer to recipient).
        access(all) view fun getAllocatedProtocolFee(): UFix64 {
            return self.allocatedProtocolFee
        }
        
        /// Returns total prize pool balance including pending yield.
        access(all) view fun getPrizePoolBalance(): UFix64 {
            return self.prizeDistributor.getPrizePoolBalance() + self.allocatedPrizeYield
        }

        access(all) view fun getUnclaimedProtocolBalance(): UFix64 {
            return self.unclaimedProtocolFeeVault.balance
        }

        access(all) view fun getProtocolRecipient(): Address? {
            return self.protocolFeeRecipientCap?.address
        }
        
        access(all) view fun hasProtocolRecipient(): Bool {
            if let cap = self.protocolFeeRecipientCap {
                return cap.check()
            }
            return false
        }
        
        access(all) view fun getTotalProtocolFeeForwarded(): UFix64 {
            return self.totalProtocolFeeForwarded
        }
        
        /// Set protocol fee recipient for forwarding at draw time.
        access(contract) fun setProtocolFeeRecipient(cap: Capability<&{FungibleToken.Receiver}>?) {
            self.protocolFeeRecipientCap = cap
        }

        /// Withdraws funds from the unclaimed protocol fee vault.
        /// Called by Admin.withdrawUnclaimedProtocolFee.
        /// @param amount - Maximum amount to withdraw
        /// @return Vault containing withdrawn funds (may be less than requested)
        access(contract) fun withdrawUnclaimedProtocolFee(amount: UFix64): @{FungibleToken.Vault} {
            let available = self.unclaimedProtocolFeeVault.balance
            let withdrawAmount = amount > available ? available : amount
            return <- self.unclaimedProtocolFeeVault.withdraw(amount: withdrawAmount)
        }

        // ============================================================
        // ENTRY VIEW FUNCTIONS - Human-readable UI helpers
        // ============================================================
        // "Entries" represent the user's PROJECTED prize weight at round end.
        // 
        // Key distinction:
        // - TWAB (accumulated): Historical weight from actual balance changes
        // - Entries (projected): TWAB projected to round end assuming current
        //   balance is maintained until the draw
        // 
        // With NORMALIZED TWAB, entries ≈ average shares over the full round:
        // - 10 shares held for full round → 10 entries
        // - 10 shares deposited halfway → ~5 entries (only half the round)
        // - At next round: same 10 shares → 10 entries immediately (fresh start)
        //
        // The projection provides immediate UI feedback after deposits:
        // - User deposits → sees projected entries right away
        // - Actual prize weight is finalized during processBatch
        // ============================================================
        
        /// Returns the user's projected entries at round end.
        /// Uses NORMALIZED projected TWAB assuming current shares are held until round end.
        /// With normalized TWAB, the result is already in "average shares" units.
        /// 
        /// This projection shows what the user's entries WILL be if they maintain
        /// their current balance until the draw. This provides immediate feedback
        /// after deposits/withdrawals.
        /// 
        /// During intermission, returns the user's share balance since that will be
        /// their full TWAB/entries at the beginning of the next round.
        /// 
        /// Examples:
        /// - 10 shares deposited at round start → 10 entries (immediately)
        /// - 10 shares deposited at halfway point → ~5 entries (prorated)
        /// - 10 shares held for full round → 10 entries
        /// - During intermission: returns current share balance
        access(all) view fun getUserEntries(receiverID: UInt64): UFix64 {
            // During intermission, return share balance (their full entries for next round)
            if self.activeRound == nil {
                return self.shareTracker.getUserShares(receiverID: receiverID)
            }
            
            if let round = &self.activeRound as &Round? {
                let roundDuration = round.getDuration()
                if roundDuration == 0.0 {
                    return 0.0
                }

                let roundEndTime = round.getEndTime()
                let shares = self.shareTracker.getUserShares(receiverID: receiverID)

                // Project NORMALIZED TWAB forward to round end (assumes current shares held until end)
                // With normalized TWAB, result is already "average shares" - no division needed
                let projectedNormalizedWeight = round.getCurrentTWAB(
                    receiverID: receiverID,
                    currentShares: shares,
                    atTime: roundEndTime
                )

                // TWAB is already normalized (divided by duration internally)
                return projectedNormalizedWeight
            }
            return 0.0
        }
        
        /// Returns how far through the current round we are (0.0 to 1.0+).
        /// - 0.0 = round just started (or in intermission)
        /// - 0.5 = halfway through round
        /// - 1.0 = round complete, ready for next draw
        access(all) view fun getDrawProgressPercent(): UFix64 {
            if let round = &self.activeRound as &Round? {
                let roundDuration = round.getDuration()
                if roundDuration == 0.0 {
                    return 0.0
                }
                let elapsed = self.getRoundElapsedTime()
                return elapsed / roundDuration
            }
            return 0.0
        }

        /// Returns time remaining until round ends (in seconds).
        /// Returns 0.0 if round has ended, in intermission, or draw can happen now.
        access(all) view fun getTimeUntilNextDraw(): UFix64 {
            if let round = &self.activeRound as &Round? {
                let endTime = round.getEndTime()
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
    
    /// Represents a user's balance in a pool.
    /// Note: Deposit history is tracked off-chain via events.
    access(all) struct PoolBalance {
        /// Total withdrawable balance (shares × sharePrice).
        /// This is what the user can actually withdraw right now.
        access(all) let totalBalance: UFix64
        
        /// Lifetime total of prizes won (cumulative counter).
        /// This never decreases - useful for leaderboards and statistics.
        access(all) let totalEarnedPrizes: UFix64
        
        /// Creates a PoolBalance summary.
        /// @param totalBalance - Current withdrawable balance
        /// @param totalEarnedPrizes - Lifetime prize winnings
        init(totalBalance: UFix64, totalEarnedPrizes: UFix64) {
            self.totalBalance = totalBalance
            self.totalEarnedPrizes = totalEarnedPrizes
        }
    }
    
    // ============================================================
    // POOL POSITION COLLECTION RESOURCE
    // ============================================================
    
    /// User's position collection for interacting with prize-linked accounts pools.
    /// 
    /// This resource represents a user's account in the prize rewards protocol.
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
                self.owner != nil: "Collection must be stored in an account"
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            // Register our UUID with the owner address for address resolution
            poolRef.registerReceiver(receiverID: self.uuid, ownerAddress: self.owner!.address)
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
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            // Delegate to pool's deposit function with owner address for tracking
            poolRef.deposit(from: <- from, receiverID: self.uuid, ownerAddress: self.owner?.address)
        }
        
        /// Withdraws funds from a pool.
        /// 
        /// Can withdraw up to total balance (deposits + earned interest).
        /// May return empty vault if yield source has liquidity issues.
        /// 
        /// @param poolID - ID of pool to withdraw from
        /// @param amount - Amount to withdraw (must be > 0)
        /// @return Vault containing withdrawn funds
        access(PositionOps) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                amount > 0.0: "Withdraw amount must be greater than 0"
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            // Pass owner address for tracking current owner
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid, ownerAddress: self.owner?.address)
        }
        
        /// Claims a pending NFT prize.
        /// 
        /// NFT prizes won in draws are stored in pending claims until picked up.
        /// Use getPendingNFTIDs() to see available NFTs.
        /// 
        /// @param poolID - ID of pool where NFT was won
        /// @param nftIndex - Index in pending claims array (0-based)
        /// @return The claimed NFT resource
        access(PositionOps) fun claimPendingNFT(poolID: UInt64, nftIndex: Int): @{NonFungibleToken.NFT} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            
            return <- poolRef.claimPendingNFT(receiverID: self.uuid, nftIndex: nftIndex)
        }
        
        /// Returns count of pending NFT claims for this user in a pool.
        /// @param poolID - Pool ID to check
        /// @return Number of NFTs awaiting claim
        access(all) view fun getPendingNFTCount(poolID: UInt64): Int {
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return poolRef.getPendingNFTCount(receiverID: self.uuid)
            }
            return 0
        }
        
        /// Returns UUIDs of all pending NFT claims for this user in a pool.
        /// @param poolID - Pool ID to check
        /// @return Array of NFT UUIDs
        access(all) fun getPendingNFTIDs(poolID: UInt64): [UInt64] {
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return poolRef.getPendingNFTIDs(receiverID: self.uuid)
            }
            return []
        }
        
        /// Returns this collection's receiver ID (its UUID).
        /// This is the key used to identify the user in all pools.
        access(all) view fun getReceiverID(): UInt64 {
            return self.uuid
        }
        
        /// Returns a complete balance breakdown for this user in a pool.
        /// @param poolID - Pool ID to check
        /// @return PoolBalance struct with balance and lifetime prizes
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            // Return zero balance if not registered
            if self.registeredPools[poolID] == nil {
                return PoolBalance(totalBalance: 0.0, totalEarnedPrizes: 0.0)
            }

            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return PoolBalance(
                    totalBalance: poolRef.getReceiverTotalBalance(receiverID: self.uuid),
                    totalEarnedPrizes: poolRef.getReceiverTotalEarnedPrizes(receiverID: self.uuid)
                )
            }
            return PoolBalance(totalBalance: 0.0, totalEarnedPrizes: 0.0)
        }
        
        /// Returns the user's projected entry count for the current draw.
        /// Entries represent prize weight - higher entries = better odds.
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
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return poolRef.getUserEntries(receiverID: self.uuid)
            }
            return 0.0
        }
    }
    
    // ============================================================
    // SPONSOR POSITION COLLECTION RESOURCE
    // ============================================================
    
    /// Sponsor's position collection for prize-ineligible deposits.
    /// 
    /// This resource allows users to make deposits that earn rewards yield
    /// but are NOT eligible to win prizes. Useful for:
    /// - Protocol treasuries seeding initial liquidity
    /// - Foundations incentivizing participation without competing
    /// - Users who want yield but don't want prize exposure
    /// 
    /// A single account can have BOTH a PoolPositionCollection (prize-eligible)
    /// AND a SponsorPositionCollection (prize-ineligible) simultaneously.
    /// Each has its own UUID, enabling independent positions.
    /// 
    /// ⚠️ CRITICAL SECURITY WARNING:
    /// This resource's UUID serves as the account key for ALL sponsor deposits.
    /// - All funds and shares are keyed to this resource's UUID
    /// - If this resource is destroyed or lost, funds become INACCESSIBLE
    /// - Users should treat this resource like a wallet private key
    /// 
    /// USAGE:
    /// 1. Create and store: account.storage.save(<- createSponsorPositionCollection(), to: path)
    /// 2. Deposit: collection.deposit(poolID: 0, from: <- vault)
    /// 3. Withdraw: let vault <- collection.withdraw(poolID: 0, amount: 10.0)
    access(all) resource SponsorPositionCollection {
        /// Tracks which pools this collection is registered with.
        access(self) let registeredPools: {UInt64: Bool}
        
        init() {
            self.registeredPools = {}
        }
        
        /// Returns this collection's receiver ID (UUID).
        /// Used internally to identify this sponsor's position in pools.
        access(all) view fun getReceiverID(): UInt64 {
            return self.uuid
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
        
        /// Deposits funds as a sponsor (prize-ineligible).
        /// 
        /// Sponsors earn rewards yield but cannot win prizes.
        /// Requires PositionOps entitlement.
        /// 
        /// @param poolID - ID of pool to deposit into
        /// @param from - Vault containing funds to deposit (consumed)
        access(PositionOps) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault}) {
            // Track registration locally
            if self.registeredPools[poolID] == nil {
                self.registeredPools[poolID] = true
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            // Pass owner address directly (sponsors don't use capability-based lookup)
            poolRef.sponsorDeposit(from: <- from, receiverID: self.uuid, ownerAddress: self.owner?.address)
        }
        
        /// Withdraws funds from a pool.
        /// 
        /// Can withdraw up to total balance (deposits + earned interest).
        /// May return empty vault if yield source has liquidity issues.
        /// 
        /// @param poolID - ID of pool to withdraw from
        /// @param amount - Amount to withdraw (must be > 0)
        /// @return Vault containing withdrawn funds
        access(PositionOps) fun withdraw(poolID: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                amount > 0.0: "Withdraw amount must be greater than 0"
                self.registeredPools[poolID] == true: "Not registered with pool"
            }
            
            let poolRef = PrizeLinkedAccounts.getPoolInternal(poolID)
            // Pass owner address directly (sponsors don't use capability-based lookup)
            return <- poolRef.withdraw(amount: amount, receiverID: self.uuid, ownerAddress: self.owner?.address)
        }
        
        /// Returns the sponsor's share balance in a pool.
        /// @param poolID - Pool ID to check
        access(all) view fun getPoolShares(poolID: UInt64): UFix64 {
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return poolRef.getUserRewardsShares(receiverID: self.uuid)
            }
            return 0.0
        }
        
        /// Returns the sponsor's asset balance in a pool (shares converted to assets).
        /// @param poolID - Pool ID to check
        access(all) view fun getPoolAssetBalance(poolID: UInt64): UFix64 {
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return poolRef.getReceiverTotalBalance(receiverID: self.uuid)
            }
            return 0.0
        }
        
        /// Returns 0.0 - sponsors have no prize entries by design.
        /// @param poolID - Pool ID to check
        /// @return Always 0.0 (sponsors are prize-ineligible)
        access(all) view fun getPoolEntries(poolID: UInt64): UFix64 {
            return 0.0  // Sponsors are never prize-eligible
        }
        
        /// Returns a complete balance breakdown for this sponsor in a pool.
        /// Note: totalEarnedPrizes will always be 0 since sponsors cannot win.
        /// @param poolID - Pool ID to check
        /// @return PoolBalance struct with balance components
        access(all) fun getPoolBalance(poolID: UInt64): PoolBalance {
            // Return zero balance if not registered
            if self.registeredPools[poolID] == nil {
                return PoolBalance(totalBalance: 0.0, totalEarnedPrizes: 0.0)
            }
            
            if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
                return PoolBalance(
                    totalBalance: poolRef.getReceiverTotalBalance(receiverID: self.uuid),
                    totalEarnedPrizes: 0.0  // Sponsors cannot win prizes
                )
            }
            return PoolBalance(totalBalance: 0.0, totalEarnedPrizes: 0.0)
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
            ?? panic("Cannot get Pool: Pool with ID \(poolID) does not exist")
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
    /// let collection <- PrizeLinkedAccounts.createPoolPositionCollection()
    /// account.storage.save(<- collection, to: PrizeLinkedAccounts.PoolPositionCollectionStoragePath)
    /// ```
    /// 
    /// @return New PoolPositionCollection resource
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    /// Creates a new SponsorPositionCollection for a user.
    /// 
    /// Sponsors can deposit funds that earn rewards yield but are
    /// NOT eligible to win prizes. A single account can have
    /// both a PoolPositionCollection and SponsorPositionCollection.
    /// 
    /// Typical usage:
    /// ```
    /// let collection <- PrizeLinkedAccounts.createSponsorPositionCollection()
    /// account.storage.save(<- collection, to: PrizeLinkedAccounts.SponsorPositionCollectionStoragePath)
    /// ```
    /// 
    /// @return New SponsorPositionCollection resource
    access(all) fun createSponsorPositionCollection(): @SponsorPositionCollection {
        return <- create SponsorPositionCollection()
    }

    /// Starts a prize draw for a pool (Phase 1 of 3). PERMISSIONLESS.
    ///
    /// Anyone can call this when the round has ended and no draw is in progress.
    /// This ensures draws cannot stall if admin is unavailable.
    ///
    /// Preconditions (enforced internally):
    /// - Pool must be in Normal state (not emergency/paused)
    /// - No pending draw in progress
    /// - Round must have ended (canDrawNow() returns true)
    ///
    /// @param poolID - ID of the pool to start draw for
    access(all) fun startDraw(poolID: UInt64) {
        let poolRef = self.getPoolInternal(poolID)
        poolRef.startDraw()
    }

    /// Processes a batch of receivers for weight capture (Phase 2 of 3). PERMISSIONLESS.
    ///
    /// Anyone can call this to advance batch processing.
    /// Call repeatedly until return value is 0 (or isDrawBatchComplete()).
    ///
    /// Preconditions (enforced internally):
    /// - Draw must be in progress
    /// - Batch processing not complete
    ///
    /// @param poolID - ID of the pool
    /// @param limit - Maximum receivers to process this batch
    /// @return Number of receivers remaining to process
    access(all) fun processDrawBatch(poolID: UInt64, limit: Int): Int {
        let poolRef = self.getPoolInternal(poolID)
        return poolRef.processDrawBatch(limit: limit)
    }

    /// Completes a prize draw for a pool (Phase 3 of 3). PERMISSIONLESS.
    ///
    /// Anyone can call this after batch processing is complete and at least 1 block
    /// has passed since startDraw() (for randomness fulfillment).
    /// Fulfills randomness request, selects winners, and distributes prizes.
    /// Prizes are auto-compounded into winners' deposits.
    ///
    /// Preconditions (enforced internally):
    /// - startDraw() must have been called (randomness already requested)
    /// - Batch processing must be complete
    /// - Must be in a different block than startDraw()
    ///
    /// @param poolID - ID of the pool to complete draw for
    access(all) fun completeDraw(poolID: UInt64) {
        let poolRef = self.getPoolInternal(poolID)
        poolRef.completeDraw()
    }

    // ============================================================
    // ENTRY QUERY FUNCTIONS - Contract-level convenience accessors
    // ============================================================
    // These functions provide easy access to entry information for UI/scripts.
    // "Entries" represent the user's prize weight for the current draw:
    // - entries = currentTWAB / elapsedTime
    // - $10 deposited at start of draw = 10 entries
    // - $10 deposited halfway through = ~5 entries (prorated based on elapsed time)
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
    // POOL STATE MACHINE (Contract-level convenience functions)
    // ============================================================

    /// STATE 1: Returns whether a round is actively in progress (timer hasn't expired).
    access(all) view fun isRoundActive(poolID: UInt64): Bool {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.isRoundActive()
        }
        return false
    }

    /// STATE 2: Returns whether the round has ended and is waiting for draw to start.
    access(all) view fun isAwaitingDraw(poolID: UInt64): Bool {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.isAwaitingDraw()
        }
        return false
    }

    /// STATE 3: Returns whether a draw is being processed.
    access(all) view fun isDrawInProgress(poolID: UInt64): Bool {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.isDrawInProgress()
        }
        return false
    }

    /// STATE 4: Returns whether the pool is in intermission (between rounds).
    access(all) view fun isInIntermission(poolID: UInt64): Bool {
        if let poolRef = self.borrowPool(poolID: poolID) {
            return poolRef.isInIntermission()
        }
        return false
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
        
        // Minimum yield distribution threshold (100x minimum UFix64).
        // Prevents precision loss when distributing tiny amounts across percentage buckets.
        self.MINIMUM_DISTRIBUTION_THRESHOLD = 0.000001

        // Warning threshold for normalized weights (90% of UFix64 max ≈ 166 billion)
        // UFix64 max value for percentage calculations
        self.UFIX64_MAX = 184467440737.0
        
        // Warning threshold for normalized weights (90% of UFIX64_MAX ≈ 166 billion)
        // With normalized TWAB, weights are ~average shares, so this is very generous
        self.WEIGHT_WARNING_THRESHOLD = 166000000000.0

        // Maximum TVL per pool (80% of UFIX64_MAX ≈ 147 billion)
        // Provides safety margin for yield accrual and prevents overflow
        self.SAFE_MAX_TVL = 147500000000.0

        // Storage paths for user collections
        self.PoolPositionCollectionStoragePath = /storage/PrizeLinkedAccountsCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeLinkedAccountsCollection
        
        // Storage paths for sponsor collections (prize-ineligible)
        self.SponsorPositionCollectionStoragePath = /storage/PrizeLinkedAccountsSponsorCollection
        self.SponsorPositionCollectionPublicPath = /public/PrizeLinkedAccountsSponsorCollection
        
        // Storage path for admin resource
        self.AdminStoragePath = /storage/PrizeLinkedAccountsAdmin
        
        // Initialize pool storage
        self.pools <- {}
        self.nextPoolID = 0
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}