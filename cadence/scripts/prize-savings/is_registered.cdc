import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Check if a user is registered with a pool
///
/// Parameters:
/// - address: The account address to check
/// - poolID: The pool ID to check registration for
///
/// Returns: Boolean indicating if the user is registered
access(all) fun main(address: Address, poolID: UInt64): Bool {
    let collectionCap = getAccount(address)
        .capabilities.get<&{PrizeSavings.PoolPositionCollectionPublic}>(
            PrizeSavings.PoolPositionCollectionPublicPath
        )
    
    if !collectionCap.check() {
        return false
    }
    
    let collectionRef = collectionCap.borrow()!
    return collectionRef.isRegisteredWithPool(poolID: poolID)
}

