import "PrizeLinkedAccounts"

/// Get comprehensive initial state of a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "emergencyState": poolRef.getEmergencyState().rawValue,
        "allocatedRewards": poolRef.allocatedRewards,
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "allocatedPrizeYield": poolRef.getAllocatedLotteryYield(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "canDrawNow": poolRef.canDrawNow(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "totalTreasuryForwarded": poolRef.getTotalTreasuryForwarded(),
        "sharePriceIsOne": poolRef.getRewardsSharePrice() == 1.0,
        "currentRoundID": poolRef.getCurrentRoundID(),
        "roundStartTime": poolRef.getRoundStartTime(),
        "roundEndTime": poolRef.getRoundEndTime(),
        "roundDuration": poolRef.getRoundDuration(),
        "isRoundEnded": poolRef.isRoundEnded(),
        "totalSavingsShares": poolRef.getTotalRewardsShares(),
        "totalSavingsAssets": poolRef.getTotalRewardsAssets(),
        "totalSavingsDistributed": poolRef.getTotalRewardsDistributed(),
        "registeredReceiverCount": poolRef.getRegisteredReceiverIDs().length
    }
}
