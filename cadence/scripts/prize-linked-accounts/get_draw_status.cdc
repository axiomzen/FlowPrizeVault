import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Batch processing progress information
access(all) struct BatchProgress {
    access(all) let cursor: Int
    access(all) let total: Int
    access(all) let remaining: Int
    access(all) let percentComplete: UFix64
    access(all) let isComplete: Bool
    
    init(
        cursor: Int,
        total: Int,
        remaining: Int,
        percentComplete: UFix64,
        isComplete: Bool
    ) {
        self.cursor = cursor
        self.total = total
        self.remaining = remaining
        self.percentComplete = percentComplete
        self.isComplete = isComplete
    }
}

/// Draw status information structure
access(all) struct DrawStatus {
    /// True if randomness has been requested and waiting for completion
    access(all) let isDrawInProgress: Bool
    /// True if the round has ended and startDraw() can be called
    access(all) let canDrawNow: Bool
    access(all) let lastDrawTimestamp: UFix64
    access(all) let roundDuration: UFix64
    access(all) let roundEndTime: UFix64
    access(all) let secondsUntilNextDraw: UFix64
    access(all) let prizePoolBalance: UFix64
    access(all) let allocatedPrizeYield: UFix64
    access(all) let currentRoundID: UInt64
    access(all) let roundElapsedTime: UFix64
    access(all) let isRoundEnded: Bool
    /// True if there's a pending draw round (after startDraw, before completeDraw)
    access(all) let isPendingDrawInProgress: Bool
    /// True if batch processing is in progress (after startDraw, before requestRandomness)
    access(all) let isBatchInProgress: Bool
    /// True if batch processing is complete and ready for randomness request
    access(all) let isBatchComplete: Bool
    /// True if randomness has been requested and completeDraw can be called
    access(all) let isReadyForCompletion: Bool
    /// Batch progress information (nil if no batch in progress)
    access(all) let batchProgress: BatchProgress?
    
    init(
        isDrawInProgress: Bool,
        canDrawNow: Bool,
        lastDrawTimestamp: UFix64,
        roundDuration: UFix64,
        roundEndTime: UFix64,
        secondsUntilNextDraw: UFix64,
        prizePoolBalance: UFix64,
        allocatedPrizeYield: UFix64,
        currentRoundID: UInt64,
        roundElapsedTime: UFix64,
        isRoundEnded: Bool,
        isPendingDrawInProgress: Bool,
        isBatchInProgress: Bool,
        isBatchComplete: Bool,
        isReadyForCompletion: Bool,
        batchProgress: BatchProgress?
    ) {
        self.isDrawInProgress = isDrawInProgress
        self.canDrawNow = canDrawNow
        self.lastDrawTimestamp = lastDrawTimestamp
        self.roundDuration = roundDuration
        self.roundEndTime = roundEndTime
        self.secondsUntilNextDraw = secondsUntilNextDraw
        self.prizePoolBalance = prizePoolBalance
        self.allocatedPrizeYield = allocatedPrizeYield
        self.currentRoundID = currentRoundID
        self.roundElapsedTime = roundElapsedTime
        self.isRoundEnded = isRoundEnded
        self.isPendingDrawInProgress = isPendingDrawInProgress
        self.isBatchInProgress = isBatchInProgress
        self.isBatchComplete = isBatchComplete
        self.isReadyForCompletion = isReadyForCompletion
        self.batchProgress = batchProgress
    }
}

/// Get prize draw status for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: DrawStatus struct with draw timing and prize information
access(all) fun main(poolID: UInt64): DrawStatus {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Extract batch progress if available
    var batchProgress: BatchProgress? = nil
    if let progressData = poolRef.getDrawBatchProgress() {
        batchProgress = BatchProgress(
            cursor: progressData["cursor"] as? Int ?? 0,
            total: progressData["total"] as? Int ?? 0,
            remaining: progressData["remaining"] as? Int ?? 0,
            percentComplete: progressData["percentComplete"] as? UFix64 ?? 0.0,
            isComplete: progressData["isComplete"] as? Bool ?? false
        )
    }
    
    return DrawStatus(
        isDrawInProgress: poolRef.isDrawInProgress(),
        canDrawNow: poolRef.canDrawNow(),
        lastDrawTimestamp: poolRef.lastDrawTimestamp,
        roundDuration: poolRef.getRoundDuration(),
        roundEndTime: poolRef.getRoundEndTime(),
        secondsUntilNextDraw: poolRef.getTimeUntilNextDraw(),
        prizePoolBalance: poolRef.getPrizePoolBalance(),
        allocatedPrizeYield: poolRef.getAllocatedPrizeYield(),
        currentRoundID: poolRef.getCurrentRoundID(),
        roundElapsedTime: poolRef.getRoundElapsedTime(),
        isRoundEnded: poolRef.isRoundEnded(),
        isPendingDrawInProgress: poolRef.isPendingDrawInProgress(),
        isBatchInProgress: poolRef.isDrawBatchInProgress(),
        isBatchComplete: poolRef.isDrawBatchComplete(),
        isReadyForCompletion: poolRef.isReadyForDrawCompletion(),
        batchProgress: batchProgress
    )
}
