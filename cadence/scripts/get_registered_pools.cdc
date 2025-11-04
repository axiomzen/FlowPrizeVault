import PrizeVault from "../contracts/PrizeVault.cdc"

/// Get all pool IDs that a user is registered with
///
/// Parameters:
/// - address: The address of the user
///
/// Returns: Array of pool IDs
access(all) fun main(address: Address): [UInt64] {
    let cap = getAccount(address).capabilities.get<&{PrizeVault.PoolPositionCollectionPublic}>(
        PrizeVault.PoolPositionCollectionPublicPath
    )
    
    let collection = cap.borrow() ?? panic("Could not borrow PoolPositionCollection from address")
    
    return collection.getRegisteredPoolIDs()
}

