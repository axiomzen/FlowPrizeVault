import "PrizeLinkedAccounts"

/// Get a pool's projected share price, accounting for unsync'd yield or deficit.
/// Returns both the projected and synced share price for comparison.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with:
///   - "projectedSharePrice": Share price if sync happened now
///   - "syncedSharePrice": Current share price (last synced)
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let projected = poolRef.getProjectedSharePrice()
    let synced = poolRef.getRewardsSharePrice()

    return {
        "projectedSharePrice": projected,
        "syncedSharePrice": synced
    }
}
