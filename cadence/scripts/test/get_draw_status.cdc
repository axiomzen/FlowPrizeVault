import "PrizeLinkedAccounts"

/// Get the draw status for a pool (includes batch processing state)
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return {
        "canDrawNow": poolRef.canDrawNow(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "currentRoundID": poolRef.getCurrentRoundID(),
        "isRoundEnded": poolRef.isRoundEnded(),
        "roundElapsedTime": poolRef.getRoundElapsedTime(),
        "timeUntilNextDraw": poolRef.getTimeUntilNextDraw(),
        "isPendingDrawInProgress": poolRef.isPendingDrawInProgress(),
        "isBatchInProgress": poolRef.isDrawBatchInProgress(),
        "isBatchComplete": poolRef.isDrawBatchComplete(),
        "isReadyForCompletion": poolRef.isReadyForDrawCompletion(),
        "batchProgress": poolRef.getDrawBatchProgress(),
        "isInIntermission": poolRef.isInIntermission(),
        "targetEndTime": poolRef.getCurrentRoundTargetEndTime(),
        "currentTime": getCurrentBlock().timestamp
    }
}
