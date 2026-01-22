import "PrizeLinkedAccounts"

/// Get a user's actual withdrawable balance in a pool
/// This returns the true value of their shares (shares × sharePrice)
///
/// Parameters:
/// - userAddress: The user's address
/// - poolID: The pool ID to check
///
/// Returns: Dictionary with:
///   - "actualBalance": The true withdrawable balance (shares × sharePrice)
///   - "shares": Number of shares held
///   - "sharePrice": Current share price
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)
    
    let collectionRef = account.capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    // Get the pool reference
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // The collection's UUID is the receiverID
    let receiverID = collectionRef.uuid
    
    // Get actual balance from the pool
    let actualBalance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
    let shares = poolRef.getUserRewardsShares(receiverID: receiverID)
    let sharePrice = poolRef.getRewardsSharePrice()
    
    return {
        "actualBalance": actualBalance,
        "shares": shares,
        "sharePrice": sharePrice
    }
}
