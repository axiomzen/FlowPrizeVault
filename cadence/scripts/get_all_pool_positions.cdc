import PrizeVault from "../contracts/PrizeVault.cdc"

/// Get detailed positions for all pools a user is registered with
///
/// Parameters:
/// - address: The address of the user
///
/// Returns: Array of PoolPosition structs containing detailed balance information
access(all) fun main(address: Address): [PrizeVault.PoolPosition] {
    let cap = getAccount(address).capabilities.get<&{PrizeVault.PoolPositionCollectionPublic}>(
        PrizeVault.PoolPositionCollectionPublicPath
    )
    
    let collection = cap.borrow() ?? panic("Could not borrow PoolPositionCollection from address")
    
    return collection.getAllPoolPositions()
}

