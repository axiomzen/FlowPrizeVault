import "PrizeLinkedAccounts"

/// Get distribution strategy details for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    
    // Calculate a test distribution to extract percentages
    let testPlan = config.calculateDistribution(totalAmount: 1.0)
    
    return {
        "rewardsPercent": testPlan.rewardsAmount,
        "prizePercent": testPlan.prizeAmount,
        "treasuryPercent": testPlan.treasuryAmount
    }
}

