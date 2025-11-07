import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Get overall pool statistics
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with pool stats
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let config = poolRef.getConfig()
    
    return {
        "poolID": poolID,
        "totalDeposited": poolRef.totalDeposited,
        "totalStaked": poolRef.totalStaked,
        "lastDrawBlock": poolRef.lastDrawBlock,
        "currentBlock": getCurrentBlock().height,
        "canDrawNow": poolRef.canDrawNow(),
        "isDrawInProgress": poolRef.isDrawInProgress(),
        "minimumDeposit": config.minimumDeposit,
        "blocksPerDraw": config.blocksPerDraw,
        "assetType": config.assetType.identifier,
        "distributionStrategy": config.distributionStrategy.getStrategyName(),
        "hasWinnerTracker": poolRef.hasWinnerTracker()
    }
}

