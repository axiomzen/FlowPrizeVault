import "PrizeSavings"

/// Get the total deposits and staked amounts for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return {
        "totalDeposited": poolRef.totalDeposited,
        "totalStaked": poolRef.totalStaked
    }
}

