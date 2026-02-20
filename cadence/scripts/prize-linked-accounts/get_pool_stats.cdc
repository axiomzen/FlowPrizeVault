import "PrizeLinkedAccounts"

/// Pool statistics structure
access(all) struct PoolStats {
    access(all) let poolID: UInt64
    access(all) let userPoolBalance: UFix64
    access(all) let prizePoolBalance: UFix64
    access(all) let totalProtocolFeeForwarded: UFix64
    access(all) let totalRewardsDistributed: UFix64
    access(all) let availableYieldRewards: UFix64
    access(all) let sharePrice: UFix64
    access(all) let totalShares: UFix64
    access(all) let totalAssets: UFix64
    access(all) let registeredUserCount: Int
    access(all) let isDrawInProgress: Bool
    access(all) let canDrawNow: Bool
    access(all) let lastDrawTimestamp: UFix64
    access(all) let roundDuration: UFix64
    access(all) let minimumDeposit: UFix64
    access(all) let emergencyState: UInt8
    access(all) let currentRoundID: UInt64
    access(all) let roundStartTime: UFix64
    access(all) let roundElapsedTime: UFix64
    access(all) let isRoundEnded: Bool
    /// True if pool is in intermission (between rounds, activeRound is nil)
    access(all) let isInIntermission: Bool

    init(
        poolID: UInt64,
        userPoolBalance: UFix64,
        prizePoolBalance: UFix64,
        totalProtocolFeeForwarded: UFix64,
        totalRewardsDistributed: UFix64,
        availableYieldRewards: UFix64,
        sharePrice: UFix64,
        totalShares: UFix64,
        totalAssets: UFix64,
        registeredUserCount: Int,
        isDrawInProgress: Bool,
        canDrawNow: Bool,
        lastDrawTimestamp: UFix64,
        roundDuration: UFix64,
        minimumDeposit: UFix64,
        emergencyState: UInt8,
        currentRoundID: UInt64,
        roundStartTime: UFix64,
        roundElapsedTime: UFix64,
        isRoundEnded: Bool,
        isInIntermission: Bool
    ) {
        self.poolID = poolID
        self.userPoolBalance = userPoolBalance
        self.prizePoolBalance = prizePoolBalance
        self.totalProtocolFeeForwarded = totalProtocolFeeForwarded
        self.totalRewardsDistributed = totalRewardsDistributed
        self.availableYieldRewards = availableYieldRewards
        self.sharePrice = sharePrice
        self.totalShares = totalShares
        self.totalAssets = totalAssets
        self.registeredUserCount = registeredUserCount
        self.isDrawInProgress = isDrawInProgress
        self.canDrawNow = canDrawNow
        self.lastDrawTimestamp = lastDrawTimestamp
        self.roundDuration = roundDuration
        self.minimumDeposit = minimumDeposit
        self.emergencyState = emergencyState
        self.currentRoundID = currentRoundID
        self.roundStartTime = roundStartTime
        self.roundElapsedTime = roundElapsedTime
        self.isRoundEnded = isRoundEnded
        self.isInIntermission = isInIntermission
    }
}

/// Get comprehensive statistics for a PrizeLinkedAccounts pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: PoolStats struct with all pool information
access(all) fun main(poolID: UInt64): PoolStats {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let config = poolRef.getConfig()
    
    return PoolStats(
        poolID: poolID,
        userPoolBalance: poolRef.userPoolBalance,
        prizePoolBalance: poolRef.getPrizePoolBalance(),
        totalProtocolFeeForwarded: poolRef.getTotalProtocolFeeForwarded(),
        totalRewardsDistributed: poolRef.getTotalRewardsDistributed(),
        availableYieldRewards: poolRef.getAvailableYieldRewards(),
        sharePrice: poolRef.getRewardsSharePrice(),
        totalShares: poolRef.getTotalRewardsShares(),
        totalAssets: poolRef.getTotalRewardsAssets(),
        registeredUserCount: poolRef.getRegisteredReceiverIDs().length,
        isDrawInProgress: poolRef.isDrawInProgress(),
        canDrawNow: poolRef.canDrawNow(),
        lastDrawTimestamp: poolRef.lastDrawTimestamp,
        roundDuration: poolRef.getRoundDuration(),
        minimumDeposit: config.minimumDeposit,
        emergencyState: poolRef.getEmergencyState().rawValue,
        currentRoundID: poolRef.getCurrentRoundID(),
        roundStartTime: poolRef.getRoundStartTime(),
        roundElapsedTime: poolRef.getRoundElapsedTime(),
        isRoundEnded: poolRef.isRoundEnded(),
        isInIntermission: poolRef.isInIntermission()
    )
}
