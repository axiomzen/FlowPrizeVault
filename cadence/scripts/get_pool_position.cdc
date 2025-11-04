import PrizeVault from "../contracts/PrizeVault.cdc"

/// Get detailed position for a specific pool
///
/// Parameters:
/// - address: The address of the user
/// - poolID: The ID of the pool
///
/// Returns: PoolPosition struct with detailed balance information
access(all) fun main(address: Address, poolID: UInt64): PrizeVault.PoolPosition {
    let cap = getAccount(address).capabilities.get<&{PrizeVault.PoolPositionCollectionPublic}>(
        PrizeVault.PoolPositionCollectionPublicPath
    )
    
    let collection = cap.borrow() ?? panic("Could not borrow PoolPositionCollection from address")
    
    return collection.getPoolPosition(poolID: poolID)
}

