import "PrizeLinkedAccounts"

/// Fork-test: Batch processing progress information
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

/// Fork-test: Draw status information structure
access(all) struct DrawStatus {
    // ============================================================
    // POOL STATE MACHINE (use these for simple state checks)
    // ============================================================
    // One of: "ROUND_ACTIVE", "AWAITING_DRAW", "DRAW_PROCESSING", "INTERMISSION"
    access(all) let poolState: String
    /// STATE 1: Round in progress, timer hasn't expired
    access(all) let isRoundActive: Bool
    /// STATE 2: Round ended, waiting for admin to call startDraw()
    access(all) let isAwaitingDraw: Bool
    /// STATE 3: Draw ceremony in progress (batch processing + winner selection)
    access(all) let isDrawProcessing: Bool
    /// STATE 4: Draw complete, waiting for admin to call startNextRound()
    access(all) let isIntermission: Bool

    // ============================================================
    // DETAILED STATUS (for progress bars, debugging, etc.)
    // ============================================================
    /// DEPRECATED: Use isDrawProcessing instead
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
    /// True if batch processing is in progress (after startDraw, before batch complete)
    access(all) let isBatchInProgress: Bool
    /// True if batch processing is complete and ready for completeDraw
    access(all) let isBatchComplete: Bool
    /// True if completeDraw can be called now
    access(all) let isReadyForCompletion: Bool
    /// Batch progress information (nil if no batch in progress)
    access(all) let batchProgress: BatchProgress?
    /// DEPRECATED: Use isIntermission instead (this was inaccurate during draw processing)
    access(all) let isInIntermission: Bool
    /// Target end time for the current round (admin can modify before startDraw)
    access(all) let targetEndTime: UFix64
    /// Current block timestamp for reference
    access(all) let currentTime: UFix64

    init(
        poolState: String,
        isRoundActive: Bool,
        isAwaitingDraw: Bool,
        isDrawProcessing: Bool,
        isIntermission: Bool,
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
        batchProgress: BatchProgress?,
        isInIntermission: Bool,
        targetEndTime: UFix64,
        currentTime: UFix64
    ) {
        self.poolState = poolState
        self.isRoundActive = isRoundActive
        self.isAwaitingDraw = isAwaitingDraw
        self.isDrawProcessing = isDrawProcessing
        self.isIntermission = isIntermission
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
        self.isInIntermission = isInIntermission
        self.targetEndTime = targetEndTime
        self.currentTime = currentTime
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

    // Compute pool state from individual boolean functions
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

    return DrawStatus(
        // Pool state machine (mutually exclusive states)
        poolState: poolState,
        isRoundActive: poolRef.isRoundActive(),
        isAwaitingDraw: poolRef.isAwaitingDraw(),
        isDrawProcessing: poolRef.isDrawInProgress(),
        isIntermission: poolRef.isInIntermission(),
        // Detailed status
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
        isPendingDrawInProgress: poolRef.isDrawInProgress(),
        isBatchInProgress: poolRef.isDrawBatchInProgress(),
        isBatchComplete: poolRef.isDrawBatchComplete(),
        isReadyForCompletion: poolRef.isReadyForDrawCompletion(),
        batchProgress: batchProgress,
        isInIntermission: poolRef.isInIntermission(),
        targetEndTime: poolRef.getCurrentRoundTargetEndTime(),
        currentTime: getCurrentBlock().timestamp
    )
}
