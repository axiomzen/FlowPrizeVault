import "PrizeSavings"

/// Get detailed share info for a user for precision testing
/// Provides shares and their calculated asset value for comparison
///
/// Parameters:
/// - userAddress: The user's address
/// - poolID: The pool ID to check
///
/// Returns: Dictionary with:
///   - "shares": User's share balance
///   - "assetValue": Calculated asset value (shares × sharePrice)
///   - "sharePrice": Current share price
///   - "totalEarnedPrizes": Lifetime lottery prizes won
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)
    
    let collectionRef = account.capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    // Get the pool reference
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // The collection's UUID is the receiverID
    let receiverID = collectionRef.uuid
    
    let shares = poolRef.getUserSavingsShares(receiverID: receiverID)
    let sharePrice = poolRef.getSavingsSharePrice()
    let assetValue = shares * sharePrice
    let totalEarnedPrizes = poolRef.getReceiverTotalEarnedPrizes(receiverID: receiverID)
    
    return {
        "shares": shares,
        "assetValue": assetValue,
        "sharePrice": sharePrice,
        "totalEarnedPrizes": totalEarnedPrizes
    }
}
