import PrizeVault from "../contracts/PrizeVault.cdc"

/// Check if a user has any active positions (deposits, prizes, or pending withdrawals)
/// This should be checked before destroying the collection
///
/// Parameters:
/// - address: The address of the user
///
/// Returns: true if user has active positions, false otherwise
access(all) fun main(address: Address): Bool {
    let cap = getAccount(address).capabilities.get<&{PrizeVault.PoolPositionCollectionPublic}>(
        PrizeVault.PoolPositionCollectionPublicPath
    )
    
    let collection = cap.borrow() ?? panic("Could not borrow PoolPositionCollection from address")
    
    return collection.hasActivePosition()
}

