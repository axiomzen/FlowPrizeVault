import "PrizeSavings"

/// Get a user's entry count for a specific pool
/// Returns the projected entries at draw time (what determines lottery weight)
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    let account = getAccount(userAddress)
    
    // Get the user's receiver ID from their collection
    let collectionRef = account.capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let receiverID = collectionRef.getReceiverID()
    
    // Borrow the pool and get entries
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return poolRef.getUserEntries(receiverID: receiverID)
}
