import "PrizeSavings"

/// Debug script to get all entry-related values for a user
access(all) fun main(userAddress: Address, poolID: UInt64): {String: AnyStruct} {
    let account = getAccount(userAddress)
    
    // Get the user's receiver ID from their collection
    let collectionRef = account.capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let receiverID = collectionRef.getReceiverID()
    
    // Borrow the pool
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get pool config for draw interval
    let config = poolRef.getConfig()
    let drawIntervalSeconds = config.drawIntervalSeconds
    
    // Get TWAB and balance info from savings distributor
    let userTimeWeightedShares = poolRef.getUserTimeWeightedShares(receiverID: receiverID)
    let userSavingsValue = poolRef.getUserSavingsValue(receiverID: receiverID)
    let userDeposit = poolRef.getReceiverDeposit(receiverID: receiverID)
    
    // Get epoch info
    let epochStartTime = poolRef.getEpochStartTime()
    let epochElapsedTime = poolRef.getEpochElapsedTime()
    let currentEpochID = poolRef.getCurrentEpochID()
    
    // Get entries (projected)
    let entries = poolRef.getUserEntries(receiverID: receiverID)
    
    // Get draw progress
    let drawProgress = poolRef.getDrawProgressPercent()
    let timeUntilDraw = poolRef.getTimeUntilNextDraw()
    
    return {
        "receiverID": receiverID,
        "drawIntervalSeconds": drawIntervalSeconds,
        "userTimeWeightedShares": userTimeWeightedShares,
        "userSavingsValue": userSavingsValue,
        "userDeposit": userDeposit,
        "epochStartTime": epochStartTime,
        "epochElapsedTime": epochElapsedTime,
        "currentEpochID": currentEpochID,
        "entries": entries,
        "drawProgress": drawProgress,
        "timeUntilDraw": timeUntilDraw
    }
}
