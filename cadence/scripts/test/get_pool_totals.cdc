import "PrizeSavings"

/// Get the total staked amounts and balances for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let allocatedSavings = poolRef.allocatedSavings
    
    return {
        "allocatedSavings": allocatedSavings,
        "totalStaked": allocatedSavings,  // Backwards-compatible alias
        "lotteryBalance": poolRef.getLotteryPoolBalance(),
        "totalTreasuryForwarded": poolRef.getTotalTreasuryForwarded()
    }
}
