import PrizeVault from "../contracts/PrizeVault.cdc"

/// Get total balance across all pools for a user
///
/// Parameters:
/// - address: The address of the user
///
/// Returns: Total balance (deposits + prizes) across all registered pools
access(all) fun main(address: Address): UFix64 {
    let cap = getAccount(address).capabilities.get<&{PrizeVault.PoolPositionCollectionPublic}>(
        PrizeVault.PoolPositionCollectionPublicPath
    )
    
    let collection = cap.borrow() ?? panic("Could not borrow PoolPositionCollection from address")
    
    return collection.getTotalBalanceAllPools()
}

