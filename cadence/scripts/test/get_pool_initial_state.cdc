import "PrizeSavings"

/// Get comprehensive initial state of a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "emergencyState": poolRef.getEmergencyState().rawValue,
        "allocatedSavings": poolRef.allocatedSavings,
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "allocatedLotteryYield": poolRef.getAllocatedLotteryYield(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "canDrawNow": poolRef.canDrawNow(),
        "lotteryPoolBalance": poolRef.getLotteryPoolBalance(),
        "totalTreasuryForwarded": poolRef.getTotalTreasuryForwarded(),
        "sharePriceIsOne": poolRef.getSavingsSharePrice() == 1.0,
        "currentRoundID": poolRef.getCurrentRoundID(),
        "roundStartTime": poolRef.getRoundStartTime(),
        "roundEndTime": poolRef.getRoundEndTime(),
        "roundDuration": poolRef.getRoundDuration(),
        "isRoundEnded": poolRef.isRoundEnded(),
        "totalSavingsShares": poolRef.getTotalSavingsShares(),
        "totalSavingsAssets": poolRef.getTotalSavingsAssets(),
        "totalSavingsDistributed": poolRef.getTotalSavingsDistributed(),
        "registeredReceiverCount": poolRef.getRegisteredUsers().length
    }
}
