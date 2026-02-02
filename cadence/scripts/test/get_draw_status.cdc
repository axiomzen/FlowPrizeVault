import "PrizeLinkedAccounts"

/// Get the draw status for a pool (includes batch processing state and state machine)
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

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

    return {
        // Pool state machine (mutually exclusive states)
        "poolState": poolState,
        "isRoundActive": poolRef.isRoundActive(),
        "isAwaitingDraw": poolRef.isAwaitingDraw(),
        "isDrawProcessing": poolRef.isDrawInProgress(),
        "isIntermission": poolRef.isInIntermission(),
        // Detailed status
        "canDrawNow": poolRef.canDrawNow(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "currentRoundID": poolRef.getCurrentRoundID(),
        "isRoundEnded": poolRef.isRoundEnded(),
        "roundElapsedTime": poolRef.getRoundElapsedTime(),
        "timeUntilNextDraw": poolRef.getTimeUntilNextDraw(),
        "isPendingDrawInProgress": poolRef.isDrawInProgress(),
        "isBatchInProgress": poolRef.isDrawBatchInProgress(),
        "isBatchComplete": poolRef.isDrawBatchComplete(),
        "isReadyForCompletion": poolRef.isReadyForDrawCompletion(),
        "batchProgress": poolRef.getDrawBatchProgress(),
        "isInIntermission": poolRef.isInIntermission(),
        "targetEndTime": poolRef.getCurrentRoundTargetEndTime(),
        "currentTime": getCurrentBlock().timestamp
    }
}
