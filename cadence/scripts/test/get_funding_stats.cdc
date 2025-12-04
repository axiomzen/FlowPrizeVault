import "PrizeSavings"

/// Get funding stats for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return poolRef.getFundingStats()
}

