import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Pool statistics structure
access(all) struct PoolStats {
    access(all) let poolID: UInt64
    access(all) let totalDeposited: UFix64
    access(all) let totalStaked: UFix64
    access(all) let lotteryPoolBalance: UFix64
    access(all) let treasuryBalance: UFix64
    access(all) let totalSavingsDistributed: UFix64
    access(all) let currentReinvestedSavings: UFix64
    access(all) let availableYieldRewards: UFix64
    access(all) let sharePrice: UFix64
    access(all) let totalShares: UFix64
    access(all) let totalAssets: UFix64
    access(all) let registeredUserCount: Int
    access(all) let isDrawInProgress: Bool
    access(all) let canDrawNow: Bool
    access(all) let lastDrawTimestamp: UFix64
    access(all) let drawIntervalSeconds: UFix64
    access(all) let minimumDeposit: UFix64
    access(all) let emergencyState: UInt8
    access(all) let currentEpochID: UInt64
    access(all) let epochStartTime: UFix64
    access(all) let epochElapsedTime: UFix64
    
    init(
        poolID: UInt64,
        totalDeposited: UFix64,
        totalStaked: UFix64,
        lotteryPoolBalance: UFix64,
        treasuryBalance: UFix64,
        totalSavingsDistributed: UFix64,
        currentReinvestedSavings: UFix64,
        availableYieldRewards: UFix64,
        sharePrice: UFix64,
        totalShares: UFix64,
        totalAssets: UFix64,
        registeredUserCount: Int,
        isDrawInProgress: Bool,
        canDrawNow: Bool,
        lastDrawTimestamp: UFix64,
        drawIntervalSeconds: UFix64,
        minimumDeposit: UFix64,
        emergencyState: UInt8,
        currentEpochID: UInt64,
        epochStartTime: UFix64,
        epochElapsedTime: UFix64
    ) {
        self.poolID = poolID
        self.totalDeposited = totalDeposited
        self.totalStaked = totalStaked
        self.lotteryPoolBalance = lotteryPoolBalance
        self.treasuryBalance = treasuryBalance
        self.totalSavingsDistributed = totalSavingsDistributed
        self.currentReinvestedSavings = currentReinvestedSavings
        self.availableYieldRewards = availableYieldRewards
        self.sharePrice = sharePrice
        self.totalShares = totalShares
        self.totalAssets = totalAssets
        self.registeredUserCount = registeredUserCount
        self.isDrawInProgress = isDrawInProgress
        self.canDrawNow = canDrawNow
        self.lastDrawTimestamp = lastDrawTimestamp
        self.drawIntervalSeconds = drawIntervalSeconds
        self.minimumDeposit = minimumDeposit
        self.emergencyState = emergencyState
        self.currentEpochID = currentEpochID
        self.epochStartTime = epochStartTime
        self.epochElapsedTime = epochElapsedTime
    }
}

/// Get comprehensive statistics for a PrizeSavings pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: PoolStats struct with all pool information
access(all) fun main(poolID: UInt64): PoolStats {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let config = poolRef.getConfig()
    
    return PoolStats(
        poolID: poolID,
        totalDeposited: poolRef.totalDeposited,
        totalStaked: poolRef.totalStaked,
        lotteryPoolBalance: poolRef.getLotteryPoolBalance(),
        treasuryBalance: poolRef.getTreasuryBalance(),
        totalSavingsDistributed: poolRef.getTotalSavingsDistributed(),
        currentReinvestedSavings: poolRef.getCurrentReinvestedSavings(),
        availableYieldRewards: poolRef.getAvailableYieldRewards(),
        sharePrice: poolRef.getSavingsSharePrice(),
        totalShares: poolRef.getTotalSavingsShares(),
        totalAssets: poolRef.getTotalSavingsAssets(),
        registeredUserCount: poolRef.getRegisteredReceiverIDs().length,
        isDrawInProgress: poolRef.isDrawInProgress(),
        canDrawNow: poolRef.canDrawNow(),
        lastDrawTimestamp: poolRef.lastDrawTimestamp,
        drawIntervalSeconds: config.drawIntervalSeconds,
        minimumDeposit: config.minimumDeposit,
        emergencyState: poolRef.getEmergencyState().rawValue,
        currentEpochID: poolRef.getCurrentEpochID(),
        epochStartTime: poolRef.getEpochStartTime(),
        epochElapsedTime: poolRef.getEpochElapsedTime()
    )
}

