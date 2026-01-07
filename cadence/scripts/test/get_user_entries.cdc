import "PrizeSavings"

/// Get a user's entry count for a specific pool
/// Returns the projected entries at draw time (what determines lottery weight)
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    // Borrow the pool and get entries directly using address
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return poolRef.getUserEntries(userAddress: userAddress)
}
