import "PrizeSavings"

/// Get the draw status for a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "canDrawNow": poolRef.canDrawNow(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "lotteryPoolBalance": poolRef.getLotteryPoolBalance(),
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "currentEpochID": poolRef.getCurrentEpochID()
    }
}

