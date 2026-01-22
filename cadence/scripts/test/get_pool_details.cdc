import "PrizeLinkedAccounts"

/// Get details of a specific pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getConfig()
    
    return {
        "poolID": poolID,
        "assetType": config.assetType.identifier,
        "minimumDeposit": config.minimumDeposit,
        "drawIntervalSeconds": config.drawIntervalSeconds
    }
}

