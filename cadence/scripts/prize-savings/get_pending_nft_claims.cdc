import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Get pending NFT prize claims for a user in a pool
///
/// Parameters:
/// - userAddress: The user's address
/// - poolID: The pool ID
///
/// Returns: Dictionary with pending NFT info
access(all) fun main(userAddress: Address, poolID: UInt64): {String: AnyStruct} {
    // Get user's collection
    let account = getAccount(userAddress)
    let collectionRef = account.capabilities.borrow<&{PrizeSavings.PoolPositionCollectionPublic}>(
        PrizeSavings.PoolPositionCollectionPublicPath
    )
    
    if collectionRef == nil {
        return {
            "hasPendingNFTs": false,
            "pendingCount": 0,
            "pendingNFTIDs": [] as [UInt64],
            "isRegistered": false
        }
    }
    
    // Check if registered with pool
    if !collectionRef!.isRegisteredWithPool(poolID: poolID) {
        return {
            "hasPendingNFTs": false,
            "pendingCount": 0,
            "pendingNFTIDs": [] as [UInt64],
            "isRegistered": false
        }
    }
    
    // Get pending NFT info via collection methods
    let pendingCount = collectionRef!.getPendingNFTCount(poolID: poolID)
    let pendingIDs = collectionRef!.getPendingNFTIDs(poolID: poolID)
    
    return {
        "hasPendingNFTs": pendingCount > 0,
        "pendingCount": pendingCount,
        "pendingNFTIDs": pendingIDs,
        "isRegistered": true
    }
}

