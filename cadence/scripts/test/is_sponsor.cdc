import "PrizeSavings"

/// Checks if a receiver is a sponsor in a pool.
/// 
/// @param poolID - ID of the pool to check
/// @param receiverID - UUID of the receiver to check
/// @return true if the receiver is a sponsor, false otherwise
access(all) fun main(poolID: UInt64, receiverID: UInt64): Bool {
    if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
        return poolRef.isSponsor(receiverID: receiverID)
    }
    return false
}

