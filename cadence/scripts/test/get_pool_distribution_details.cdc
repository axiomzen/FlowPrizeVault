import "PrizeSavings"

/// Get distribution strategy details for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    let strategy = config.distributionStrategy
    
    // Calculate a test distribution to extract percentages
    let testPlan = strategy.calculateDistribution(totalAmount: 1.0)
    
    return {
        "savingsPercent": testPlan.savingsAmount,
        "lotteryPercent": testPlan.lotteryAmount,
        "treasuryPercent": testPlan.treasuryAmount
    }
}

