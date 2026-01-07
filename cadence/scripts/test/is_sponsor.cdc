import "PrizeSavings"

/// Checks if a user is a sponsor in a pool.
/// 
/// @param poolID - ID of the pool to check
/// @param userAddress - Address of the user to check
/// @return true if the user is a sponsor, false otherwise
access(all) fun main(poolID: UInt64, userAddress: Address): Bool {
    if let poolRef = PrizeSavings.borrowPool(poolID: poolID) {
        return poolRef.isSponsor(userAddress: userAddress)
    }
    return false
}
