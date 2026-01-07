import "PrizeSavings"

/// Debug script to get all entry-related values for a user
access(all) fun main(userAddress: Address, poolID: UInt64): {String: AnyStruct} {
    // Borrow the pool
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get pool config for draw interval
    let config = poolRef.getConfig()
    let roundDuration = poolRef.getRoundDuration()
    
    // Get TWAB and balance info using user address directly
    let userTimeWeightedShares = poolRef.getUserTimeWeightedShares(userAddress: userAddress)
    let userSavingsValue = poolRef.getUserSavingsValue(userAddress: userAddress)
    let userTotalBalance = poolRef.getUserTotalBalance(userAddress: userAddress)
    
    // Get round info
    let roundStartTime = poolRef.getRoundStartTime()
    let roundElapsedTime = poolRef.getRoundElapsedTime()
    let currentRoundID = poolRef.getCurrentRoundID()
    let roundEndTime = poolRef.getRoundEndTime()
    let isRoundEnded = poolRef.isRoundEnded()
    
    // Get entries (projected)
    let entries = poolRef.getUserEntries(userAddress: userAddress)
    
    // Get draw progress
    let drawProgress = poolRef.getDrawProgressPercent()
    let timeUntilDraw = poolRef.getTimeUntilNextDraw()
    
    return {
        "userAddress": userAddress,
        "roundDuration": roundDuration,
        "userTimeWeightedShares": userTimeWeightedShares,
        "userSavingsValue": userSavingsValue,
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
