import "PrizeLinkedAccounts"

/// Get the distribution strategy name for a pool
access(all) fun main(poolID: UInt64): String {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    return config.getDistributionStrategyName()
}

