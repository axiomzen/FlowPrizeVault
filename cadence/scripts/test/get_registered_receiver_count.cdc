import "PrizeLinkedAccounts"

/// Returns the number of registered receivers (lottery-eligible) in a pool.
/// 
/// @param poolID - ID of the pool to query
/// @return Number of registered receivers
access(all) fun main(poolID: UInt64): Int {
    if let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID) {
        return poolRef.getRegisteredReceiverCount()
    }
    return 0
}

