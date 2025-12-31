import "PrizeSavings"

/// Get the current share price for a specific pool.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: The current share price (assets per share)
access(all) fun main(poolID: UInt64): UFix64 {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return poolRef.getSavingsSharePrice()
}

