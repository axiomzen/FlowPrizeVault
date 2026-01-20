import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get all pool IDs that a user is registered with
///
/// Parameters:
/// - address: The account address to check
///
/// Returns: Array of pool IDs the user is registered with
access(all) fun main(address: Address): [UInt64] {
    let collectionCap = getAccount(address)
        .capabilities.get<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        )
    
    if !collectionCap.check() {
        return []
    }
    
    let collectionRef = collectionCap.borrow()!
    return collectionRef.getRegisteredPoolIDs()
}

