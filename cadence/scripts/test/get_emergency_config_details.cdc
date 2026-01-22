import "PrizeLinkedAccounts"

/// Get emergency config details for a pool
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    let config = poolRef.getEmergencyConfig()
    
    return {
        "maxEmergencyDuration": config.maxEmergencyDuration ?? 0.0,
        "autoRecoveryEnabled": config.autoRecoveryEnabled,
        "minYieldSourceHealth": config.minYieldSourceHealth,
        "maxWithdrawFailures": config.maxWithdrawFailures,
        "partialModeDepositLimit": config.partialModeDepositLimit ?? 0.0,
        "minBalanceThreshold": config.minBalanceThreshold,
        "minRecoveryHealth": config.minRecoveryHealth
    }
}

