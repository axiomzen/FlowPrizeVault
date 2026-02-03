import PrizeLinkedAccounts from "../../cadence/contracts/PrizeLinkedAccounts.cdc"

/// Comprehensive admin dashboard for pool monitoring
///
/// Returns all relevant information for administrating a pool including:
/// - Financial metrics (deposits, share price, prize pool, protocol fees)
/// - Round status (state, timing, progress)
/// - User counts and participation
/// - Distribution strategy details
/// - Emergency state
/// - Last draw information

access(all) struct AdminDashboard {
    // ============================================================
    // IDENTIFICATION
    // ============================================================
    access(all) let poolID: UInt64
    access(all) let assetType: String
    access(all) let currentTime: UFix64

    // ============================================================
    // FINANCIAL METRICS
    // ============================================================
    access(all) let totalDeposits: UFix64
    access(all) let totalShares: UFix64
    access(all) let sharePrice: UFix64
    access(all) let prizePoolBalance: UFix64
    access(all) let allocatedPrizeYield: UFix64
    access(all) let userPoolBalance: UFix64
    access(all) let totalProtocolFeeForwarded: UFix64
    access(all) let unclaimedProtocolFee: UFix64
    access(all) let availableYieldRewards: UFix64

    // ============================================================
    // ROUND STATUS
    // ============================================================
    access(all) let poolState: String
    access(all) let currentRoundID: UInt64
    access(all) let roundStartTime: UFix64
    access(all) let targetEndTime: UFix64
    access(all) let roundDuration: UFix64
    access(all) let roundElapsedTime: UFix64
    access(all) let timeRemaining: UFix64
    access(all) let canDrawNow: Bool
    access(all) let isInIntermission: Bool

    // ============================================================
    // DRAW STATUS
    // ============================================================
    access(all) let isDrawInProgress: Bool
    access(all) let isBatchInProgress: Bool
    access(all) let isBatchComplete: Bool
    access(all) let isReadyForCompletion: Bool
    access(all) let batchCursor: Int
    access(all) let batchTotal: Int
    access(all) let batchPercentComplete: UFix64

    // ============================================================
    // USER METRICS
    // ============================================================
    access(all) let registeredUserCount: Int
    access(all) let sponsorCount: Int

    // ============================================================
    // CONFIGURATION
    // ============================================================
    access(all) let minimumDeposit: UFix64
    access(all) let distributionStrategy: String
    access(all) let rewardsPercent: UFix64
    access(all) let prizePercent: UFix64
    access(all) let protocolFeePercent: UFix64
    access(all) let prizeDistributionType: String

    // ============================================================
    // EMERGENCY STATE
    // ============================================================
    access(all) let emergencyState: UInt8
    access(all) let emergencyStateName: String

    // ============================================================
    // LAST DRAW INFO
    // ============================================================
    access(all) let lastDrawTimestamp: UFix64
    access(all) let totalRewardsDistributed: UFix64

    init(
        poolID: UInt64,
        assetType: String,
        currentTime: UFix64,
        totalDeposits: UFix64,
        totalShares: UFix64,
        sharePrice: UFix64,
        prizePoolBalance: UFix64,
        allocatedPrizeYield: UFix64,
        userPoolBalance: UFix64,
        totalProtocolFeeForwarded: UFix64,
        unclaimedProtocolFee: UFix64,
        availableYieldRewards: UFix64,
        poolState: String,
        currentRoundID: UInt64,
        roundStartTime: UFix64,
        targetEndTime: UFix64,
        roundDuration: UFix64,
        roundElapsedTime: UFix64,
        timeRemaining: UFix64,
        canDrawNow: Bool,
        isInIntermission: Bool,
        isDrawInProgress: Bool,
        isBatchInProgress: Bool,
        isBatchComplete: Bool,
        isReadyForCompletion: Bool,
        batchCursor: Int,
        batchTotal: Int,
        batchPercentComplete: UFix64,
        registeredUserCount: Int,
        sponsorCount: Int,
        minimumDeposit: UFix64,
        distributionStrategy: String,
        rewardsPercent: UFix64,
        prizePercent: UFix64,
        protocolFeePercent: UFix64,
        prizeDistributionType: String,
        emergencyState: UInt8,
        emergencyStateName: String,
        lastDrawTimestamp: UFix64,
        totalRewardsDistributed: UFix64
    ) {
        self.poolID = poolID
        self.assetType = assetType
        self.currentTime = currentTime
        self.totalDeposits = totalDeposits
        self.totalShares = totalShares
        self.sharePrice = sharePrice
        self.prizePoolBalance = prizePoolBalance
        self.allocatedPrizeYield = allocatedPrizeYield
        self.userPoolBalance = userPoolBalance
        self.totalProtocolFeeForwarded = totalProtocolFeeForwarded
        self.unclaimedProtocolFee = unclaimedProtocolFee
        self.availableYieldRewards = availableYieldRewards
        self.poolState = poolState
        self.currentRoundID = currentRoundID
        self.roundStartTime = roundStartTime
        self.targetEndTime = targetEndTime
        self.roundDuration = roundDuration
        self.roundElapsedTime = roundElapsedTime
        self.timeRemaining = timeRemaining
        self.canDrawNow = canDrawNow
        self.isInIntermission = isInIntermission
        self.isDrawInProgress = isDrawInProgress
        self.isBatchInProgress = isBatchInProgress
        self.isBatchComplete = isBatchComplete
        self.isReadyForCompletion = isReadyForCompletion
        self.batchCursor = batchCursor
        self.batchTotal = batchTotal
        self.batchPercentComplete = batchPercentComplete
        self.registeredUserCount = registeredUserCount
        self.sponsorCount = sponsorCount
        self.minimumDeposit = minimumDeposit
        self.distributionStrategy = distributionStrategy
        self.rewardsPercent = rewardsPercent
        self.prizePercent = prizePercent
        self.protocolFeePercent = protocolFeePercent
        self.prizeDistributionType = prizeDistributionType
        self.emergencyState = emergencyState
        self.emergencyStateName = emergencyStateName
        self.lastDrawTimestamp = lastDrawTimestamp
        self.totalRewardsDistributed = totalRewardsDistributed
    }
}

/// Get comprehensive admin dashboard for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: AdminDashboard struct with all pool administration info
access(all) fun main(poolID: UInt64): AdminDashboard {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let config = poolRef.getConfig()
    let currentTime = getCurrentBlock().timestamp

    // Compute pool state
    var poolState = "UNKNOWN"
    if poolRef.isRoundActive() {
        poolState = "ROUND_ACTIVE"
    } else if poolRef.isAwaitingDraw() {
        poolState = "AWAITING_DRAW"
    } else if poolRef.isDrawInProgress() {
        poolState = "DRAW_PROCESSING"
    } else if poolRef.isInIntermission() {
        poolState = "INTERMISSION"
    }

    // Get batch progress
    var batchCursor = 0
    var batchTotal = 0
    var batchPercentComplete: UFix64 = 0.0
    if let progressData = poolRef.getDrawBatchProgress() {
        batchCursor = progressData["cursor"] as? Int ?? 0
        batchTotal = progressData["total"] as? Int ?? 0
        batchPercentComplete = progressData["percentComplete"] as? UFix64 ?? 0.0
    }

    // Get distribution percentages
    let distribution = poolRef.getDistributionStrategy()
    let rewardsPercent = distribution.getRewardsPercent() * 100.0
    let prizePercent = distribution.getPrizePercent() * 100.0
    let protocolFeePercent = distribution.getProtocolFeePercent() * 100.0

    // Map emergency state to name
    let emergencyStateVal = poolRef.getEmergencyState()
    var emergencyStateName = "Unknown"
    switch emergencyStateVal.rawValue {
        case 0: emergencyStateName = "Normal"
        case 1: emergencyStateName = "Paused"
        case 2: emergencyStateName = "EmergencyMode"
        case 3: emergencyStateName = "PartialMode"
    }

    // Count sponsors (users marked as lottery-ineligible)
    var sponsorCount = 0
    for receiverID in poolRef.getRegisteredReceiverIDs() {
        if poolRef.isSponsor(receiverID: receiverID) {
            sponsorCount = sponsorCount + 1
        }
    }

    // Calculate time remaining
    let targetEnd = poolRef.getCurrentRoundTargetEndTime()
    var timeRemaining: UFix64 = 0.0
    if targetEnd > currentTime {
        timeRemaining = targetEnd - currentTime
    }

    return AdminDashboard(
        poolID: poolID,
        assetType: config.assetType.identifier,
        currentTime: currentTime,
        // Financial
        totalDeposits: poolRef.getTotalRewardsAssets(),
        totalShares: poolRef.getTotalRewardsShares(),
        sharePrice: poolRef.getRewardsSharePrice(),
        prizePoolBalance: poolRef.getPrizePoolBalance(),
        allocatedPrizeYield: poolRef.getAllocatedPrizeYield(),
        userPoolBalance: poolRef.userPoolBalance,
        totalProtocolFeeForwarded: poolRef.getTotalProtocolFeeForwarded(),
        unclaimedProtocolFee: poolRef.getUnclaimedProtocolFee(),
        availableYieldRewards: poolRef.getAvailableYieldRewards(),
        // Round status
        poolState: poolState,
        currentRoundID: poolRef.getCurrentRoundID(),
        roundStartTime: poolRef.getRoundStartTime(),
        targetEndTime: targetEnd,
        roundDuration: poolRef.getRoundDuration(),
        roundElapsedTime: poolRef.getRoundElapsedTime(),
        timeRemaining: timeRemaining,
        canDrawNow: poolRef.canDrawNow(),
        isInIntermission: poolRef.isInIntermission(),
        // Draw status
        isDrawInProgress: poolRef.isDrawInProgress(),
        isBatchInProgress: poolRef.isDrawBatchInProgress(),
        isBatchComplete: poolRef.isDrawBatchComplete(),
        isReadyForCompletion: poolRef.isReadyForDrawCompletion(),
        batchCursor: batchCursor,
        batchTotal: batchTotal,
        batchPercentComplete: batchPercentComplete,
        // Users
        registeredUserCount: poolRef.getRegisteredReceiverIDs().length,
        sponsorCount: sponsorCount,
        // Config
        minimumDeposit: config.minimumDeposit,
        distributionStrategy: distribution.getName(),
        rewardsPercent: rewardsPercent,
        prizePercent: prizePercent,
        protocolFeePercent: protocolFeePercent,
        prizeDistributionType: poolRef.getPrizeDistribution().getName(),
        // Emergency
        emergencyState: emergencyStateVal.rawValue,
        emergencyStateName: emergencyStateName,
        // Last draw
        lastDrawTimestamp: poolRef.lastDrawTimestamp,
        totalRewardsDistributed: poolRef.getTotalRewardsDistributed()
    )
}
