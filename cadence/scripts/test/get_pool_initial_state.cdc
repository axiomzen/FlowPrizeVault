import "PrizeLinkedAccounts"

/// Get comprehensive initial state of a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "emergencyState": poolRef.getEmergencyState().rawValue,
        "userPoolBalance": poolRef.userPoolBalance,
        "lastDrawTimestamp": poolRef.lastDrawTimestamp,
        "allocatedPrizeYield": poolRef.getAllocatedPrizeYield(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "canDrawNow": poolRef.canDrawNow(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "totalProtocolFeeForwarded": poolRef.getTotalProtocolFeeForwarded(),
        "sharePriceIsOne": poolRef.getRewardsSharePrice() == 1.0,
        "currentRoundID": poolRef.getCurrentRoundID(),
        "roundStartTime": poolRef.getRoundStartTime(),
        "roundEndTime": poolRef.getRoundEndTime(),
        "roundDuration": poolRef.getRoundDuration(),
        "isRoundEnded": poolRef.isRoundEnded(),
        "totalRewardsShares": poolRef.getTotalRewardsShares(),
        "totalRewardsAssets": poolRef.getTotalRewardsAssets(),
        "totalRewardsDistributed": poolRef.getTotalRewardsDistributed(),
        "registeredReceiverCount": poolRef.getRegisteredReceiverIDs().length
    }
}
