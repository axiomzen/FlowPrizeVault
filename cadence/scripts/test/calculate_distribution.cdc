import "PrizeLinkedAccounts"

/// Calculate distribution for a given total amount
access(all) fun main(poolID: UInt64, totalAmount: UFix64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    let plan = config.calculateDistribution(totalAmount: totalAmount)
    
    return {
        "rewardsAmount": plan.rewardsAmount,
        "prizeAmount": plan.prizeAmount,
        "protocolFeeAmount": plan.protocolFeeAmount
    }
}

