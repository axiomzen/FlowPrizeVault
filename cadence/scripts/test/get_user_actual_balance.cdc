import "PrizeSavings"

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
    // Get the pool reference
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get actual balance from the pool using address
    let actualBalance = poolRef.getUserTotalBalance(userAddress: userAddress)
    let shares = poolRef.getUserSavingsShares(userAddress: userAddress)
    let sharePrice = poolRef.getSavingsSharePrice()
    
    return {
        "actualBalance": actualBalance,
        "shares": shares,
        "sharePrice": sharePrice
    }
}
