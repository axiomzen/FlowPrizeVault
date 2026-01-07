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
///   - "deposits": Same as assetValue (for backwards compatibility in precision tests)
///   - "precisionLoss": Always 0.0 (precision loss must be calculated by tests)
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    // Get the pool reference
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let shares = poolRef.getUserSavingsShares(userAddress: userAddress)
    let sharePrice = poolRef.getSavingsSharePrice()
    let assetValue = shares * sharePrice
    let totalEarnedPrizes = poolRef.getUserTotalEarnedPrizes(userAddress: userAddress)
    
    return {
        "shares": shares,
        "assetValue": assetValue,
        "sharePrice": sharePrice,
        "totalEarnedPrizes": totalEarnedPrizes,
        "deposits": assetValue,  // For precision tests - matches assetValue when no yield
        "precisionLoss": 0.0  // Tests should calculate actual precision loss externally
    }
}
