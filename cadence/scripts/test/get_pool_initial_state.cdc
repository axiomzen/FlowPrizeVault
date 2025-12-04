import "PrizeSavings"

/// Get comprehensive initial state of a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "emergencyState": poolRef.getEmergencyState().rawValue,
        "totalDeposited": poolRef.totalDeposited,
        "totalStaked": poolRef.totalStaked,
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "pendingLotteryYield": poolRef.getPendingLotteryYield(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "canDrawNow": poolRef.canDrawNow(),
        "lotteryPoolBalance": poolRef.getLotteryPoolBalance(),
        "totalTreasuryForwarded": poolRef.getTotalTreasuryForwarded(),
        "sharePriceIsOne": poolRef.getSavingsSharePrice() == 1.0,
        "currentEpochID": poolRef.getCurrentEpochID(),
        "totalSavingsShares": poolRef.getTotalSavingsShares(),
        "totalSavingsAssets": poolRef.getTotalSavingsAssets(),
        "totalSavingsDistributed": poolRef.getTotalSavingsDistributed(),
        "currentReinvestedSavings": poolRef.getCurrentReinvestedSavings(),
        "registeredReceiverCount": poolRef.getRegisteredReceiverIDs().length
    }
}

