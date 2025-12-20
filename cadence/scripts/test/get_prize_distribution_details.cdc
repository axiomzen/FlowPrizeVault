import "PrizeSavings"

/// Get prize distribution details for a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    let distributionName = config.getPrizeDistributionName()
    
    return {
        "distributionName": distributionName
    }
}

