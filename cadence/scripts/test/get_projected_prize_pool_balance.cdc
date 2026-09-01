import "PrizeLinkedAccounts"

/// Get a pool's projected prize pool balance, accounting for unsync'd yield or deficit.
/// Returns both the projected and synced prize pool balance for comparison.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with:
///   - "projectedPrizePoolBalance": Prize pool if sync happened now
///   - "syncedPrizePoolBalance": Current prize pool (last synced)
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let projected = poolRef.getProjectedPrizePoolBalance()
    let synced = poolRef.getPrizePoolBalance()

    return {
        "projectedPrizePoolBalance": projected,
        "syncedPrizePoolBalance": synced
    }
}
