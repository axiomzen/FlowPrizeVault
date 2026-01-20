import "PrizeLinkedAccounts"

/// Returns the total number of sponsors in a pool.
/// 
/// @param poolID - ID of the pool to query
/// @return Number of sponsors
access(all) fun main(poolID: UInt64): Int {
    if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
        return poolRef.getSponsorCount()
    }
    return 0
}

