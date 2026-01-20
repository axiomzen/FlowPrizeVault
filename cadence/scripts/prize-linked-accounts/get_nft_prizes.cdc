import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get information about NFT prizes in a pool
///
/// Returns: Dictionary with NFT prize IDs and counts
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get available NFT prize IDs (not yet awarded)
    let availableIDs = poolRef.getAvailableNFTPrizeIDs()
    
    return {
        "availableNFTPrizeIDs": availableIDs,
        "availableCount": availableIDs.length,
        "poolID": poolID
    }
}

