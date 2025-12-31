import "PrizeSavings"

/// Get a user's savings shares for a specific pool.
///
/// Parameters:
/// - userAddress: The address of the user
/// - poolID: The pool ID to query
///
/// Returns: The user's shares in the savings distributor
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    let collectionRef = getAccount(userAddress)
        .capabilities.borrow<&{PrizeSavings.PoolPositionCollectionPublic}>(
            PrizeSavings.PoolPositionCollectionPublicPath
        ) ?? panic("Could not borrow collection")
    
    let receiverID = collectionRef.getReceiverID()
    
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return poolRef.getUserSavingsShares(receiverID: receiverID)
}

