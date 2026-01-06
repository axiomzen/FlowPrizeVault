import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Pool statistics structure
access(all) struct PoolStats {
    access(all) let poolID: UInt64
    access(all) let allocatedSavings: UFix64
    access(all) let lotteryPoolBalance: UFix64
    access(all) let totalTreasuryForwarded: UFix64
    access(all) let totalSavingsDistributed: UFix64
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
    
    init(
        poolID: UInt64,
        allocatedSavings: UFix64,
        lotteryPoolBalance: UFix64,
        totalTreasuryForwarded: UFix64,
        totalSavingsDistributed: UFix64,
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
        isRoundEnded: Bool
    ) {
        self.poolID = poolID
        self.allocatedSavings = allocatedSavings
        self.lotteryPoolBalance = lotteryPoolBalance
        self.totalTreasuryForwarded = totalTreasuryForwarded
        self.totalSavingsDistributed = totalSavingsDistributed
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
        allocatedSavings: poolRef.allocatedSavings,
        lotteryPoolBalance: poolRef.getLotteryPoolBalance(),
        totalTreasuryForwarded: poolRef.getTotalTreasuryForwarded(),
        totalSavingsDistributed: poolRef.getTotalSavingsDistributed(),
        availableYieldRewards: poolRef.getAvailableYieldRewards(),
        sharePrice: poolRef.getSavingsSharePrice(),
        totalShares: poolRef.getTotalSavingsShares(),
        totalAssets: poolRef.getTotalSavingsAssets(),
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
        isRoundEnded: poolRef.isRoundEnded()
    )
}
