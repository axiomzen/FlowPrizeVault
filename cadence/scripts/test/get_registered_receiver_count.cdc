import "PrizeSavings"

/// Returns the number of registered users (lottery-eligible) in a pool.
/// 
/// @param poolID - ID of the pool to query
/// @return Number of registered users
access(all) fun main(poolID: UInt64): Int {
    if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
        return poolRef.getRegisteredUserCount()
    }
    return 0
}
