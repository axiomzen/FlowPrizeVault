import "PrizeSavings"

/// Get detailed share info for a user for precision testing
/// Provides both shares and their calculated asset value for comparison
///
/// Parameters:
/// - userAddress: The user's address
/// - poolID: The pool ID to check
///
/// Returns: Dictionary with:
///   - "shares": User's share balance
///   - "assetValue": Calculated asset value (shares × sharePrice)
///   - "deposits": Original principal deposited
///   - "sharePrice": Current share price
///   - "precisionLoss": deposits - assetValue (positive = loss, negative = gain)
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
    let deposits = poolRef.getReceiverDeposit(receiverID: receiverID)
    
    // Calculate precision loss (deposits - current value)
    // Positive = lost value, Negative = gained value (from yield)
    let precisionLoss = deposits > assetValue ? deposits - assetValue : 0.0
    let precisionGain = assetValue > deposits ? assetValue - deposits : 0.0
    
    return {
        "shares": shares,
        "assetValue": assetValue,
        "deposits": deposits,
        "sharePrice": sharePrice,
        "precisionLoss": precisionLoss,
        "precisionGain": precisionGain
    }
}

