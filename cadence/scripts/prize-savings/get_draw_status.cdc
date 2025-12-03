import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Draw status information structure
access(all) struct DrawStatus {
    access(all) let isDrawInProgress: Bool
    access(all) let canDrawNow: Bool
    access(all) let lastDrawTimestamp: UFix64
    access(all) let drawIntervalSeconds: UFix64
    access(all) let nextDrawAvailableAt: UFix64
    access(all) let secondsUntilNextDraw: UFix64
    access(all) let lotteryPoolBalance: UFix64
    access(all) let pendingLotteryYield: UFix64
    access(all) let currentEpochID: UInt64
    access(all) let epochElapsedTime: UFix64
    access(all) let isBatchDrawInProgress: Bool
    
    init(
        isDrawInProgress: Bool,
        canDrawNow: Bool,
        lastDrawTimestamp: UFix64,
        drawIntervalSeconds: UFix64,
        nextDrawAvailableAt: UFix64,
        secondsUntilNextDraw: UFix64,
        lotteryPoolBalance: UFix64,
        pendingLotteryYield: UFix64,
        currentEpochID: UInt64,
        epochElapsedTime: UFix64,
        isBatchDrawInProgress: Bool
    ) {
        self.isDrawInProgress = isDrawInProgress
        self.canDrawNow = canDrawNow
        self.lastDrawTimestamp = lastDrawTimestamp
        self.drawIntervalSeconds = drawIntervalSeconds
        self.nextDrawAvailableAt = nextDrawAvailableAt
        self.secondsUntilNextDraw = secondsUntilNextDraw
        self.lotteryPoolBalance = lotteryPoolBalance
        self.pendingLotteryYield = pendingLotteryYield
        self.currentEpochID = currentEpochID
        self.epochElapsedTime = epochElapsedTime
        self.isBatchDrawInProgress = isBatchDrawInProgress
    }
}

/// Get lottery draw status for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: DrawStatus struct with draw timing and prize information
access(all) fun main(poolID: UInt64): DrawStatus {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let config = poolRef.getConfig()
    let currentTime = getCurrentBlock().timestamp
    let lastDraw = poolRef.lastDrawTimestamp
    let interval = config.drawIntervalSeconds
    
    let nextDrawAvailable = lastDraw + interval
    let secondsUntil = nextDrawAvailable > currentTime ? nextDrawAvailable - currentTime : 0.0
    
    return DrawStatus(
        isDrawInProgress: poolRef.isDrawInProgress(),
        canDrawNow: poolRef.canDrawNow(),
        lastDrawTimestamp: lastDraw,
        drawIntervalSeconds: interval,
        nextDrawAvailableAt: nextDrawAvailable,
        secondsUntilNextDraw: secondsUntil,
        lotteryPoolBalance: poolRef.getLotteryPoolBalance(),
        pendingLotteryYield: poolRef.getPendingLotteryYield(),
        currentEpochID: poolRef.getCurrentEpochID(),
        epochElapsedTime: poolRef.getEpochElapsedTime(),
        isBatchDrawInProgress: poolRef.isBatchDrawInProgress()
    )
}

