import "PrizeSavings"

/// Get the distribution strategy name for a pool
access(all) fun main(poolID: UInt64): String {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    return config.distributionStrategy.getStrategyName()
}

