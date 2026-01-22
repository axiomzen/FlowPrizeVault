import "PrizeLinkedAccounts"

/// Debug script to get all entry-related values for a user
access(all) fun main(userAddress: Address, poolID: UInt64): {String: AnyStruct} {
    let account = getAccount(userAddress)
    
    // Get the user's receiver ID from their collection
    let collectionRef = account.capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let receiverID = collectionRef.getReceiverID()
    
    // Borrow the pool
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get pool config for draw interval
    let config = poolRef.getConfig()
    let roundDuration = poolRef.getRoundDuration()
    
    // Get TWAB and balance info
    let userTimeWeightedShares = poolRef.getUserTimeWeightedShares(receiverID: receiverID)
    let userRewardsValue = poolRef.getUserRewardsValue(receiverID: receiverID)
    let userTotalBalance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
    
    // Get round info
    let roundStartTime = poolRef.getRoundStartTime()
    let roundElapsedTime = poolRef.getRoundElapsedTime()
    let currentRoundID = poolRef.getCurrentRoundID()
    let roundEndTime = poolRef.getRoundEndTime()
    let isRoundEnded = poolRef.isRoundEnded()
    
    // Get entries (projected)
    let entries = poolRef.getUserEntries(receiverID: receiverID)
    
    // Get draw progress
    let drawProgress = poolRef.getDrawProgressPercent()
    let timeUntilDraw = poolRef.getTimeUntilNextDraw()
    
    return {
        "receiverID": receiverID,
        "roundDuration": roundDuration,
        "userTimeWeightedShares": userTimeWeightedShares,
        "userRewardsValue": userRewardsValue,
        "userTotalBalance": userTotalBalance,
        "roundStartTime": roundStartTime,
        "roundElapsedTime": roundElapsedTime,
        "currentRoundID": currentRoundID,
        "roundEndTime": roundEndTime,
        "isRoundEnded": isRoundEnded,
        "entries": entries,
        "drawProgress": drawProgress,
        "timeUntilDraw": timeUntilDraw
    }
}
