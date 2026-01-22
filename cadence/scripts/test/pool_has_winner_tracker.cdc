import "PrizeLinkedAccounts"

/// Check if a pool has a winner tracker configured
access(all) fun main(poolID: UInt64): Bool {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return poolRef.hasWinnerTracker()
}

