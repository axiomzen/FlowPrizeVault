import "PrizeLinkedAccounts"

/// Returns the sponsor's balance in a pool.
/// 
/// @param sponsorAddress - Address of the sponsor
/// @param poolID - ID of the pool to query
/// @return Dictionary with totalBalance and totalEarnedPrizes (always 0 for sponsors)
access(all) fun main(sponsorAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(sponsorAddress)
    
    if let collection = account.capabilities.borrow<&PrizeLinkedAccounts.SponsorPositionCollection>(
        PrizeLinkedAccounts.SponsorPositionCollectionPublicPath
    ) {
        let balance = collection.getPoolBalance(poolID: poolID)
        return {
            "totalBalance": balance.totalBalance,
            "totalEarnedPrizes": balance.totalEarnedPrizes
        }
    }
    
    return {
        "totalBalance": 0.0,
        "totalEarnedPrizes": 0.0
    }
}
