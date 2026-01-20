import "PrizeLinkedAccounts"

/// Returns the sponsor's lottery entries in a pool.
/// This should always return 0.0 since sponsors are lottery-ineligible.
/// 
/// @param sponsorAddress - Address of the sponsor
/// @param poolID - ID of the pool to query
/// @return 0.0 (sponsors have no lottery entries)
access(all) fun main(sponsorAddress: Address, poolID: UInt64): UFix64 {
    let account = getAccount(sponsorAddress)
    
    if let collection = account.capabilities.borrow<&PrizeLinkedAccounts.SponsorPositionCollection>(
        PrizeLinkedAccounts.SponsorPositionCollectionPublicPath
    ) {
        return collection.getPoolEntries(poolID: poolID)
    }
    
    return 0.0
}

