import "PrizeSavings"

/// Calculate distribution for a given total amount
access(all) fun main(poolID: UInt64, totalAmount: UFix64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    let strategy = config.distributionStrategy
    let plan = strategy.calculateDistribution(totalAmount: totalAmount)
    
    return {
        "savingsAmount": plan.savingsAmount,
        "lotteryAmount": plan.lotteryAmount,
        "treasuryAmount": plan.treasuryAmount
    }
}

