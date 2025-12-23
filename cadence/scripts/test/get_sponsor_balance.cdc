import "PrizeSavings"

/// Returns the sponsor's balance breakdown in a pool.
/// 
/// @param sponsorAddress - Address of the sponsor
/// @param poolID - ID of the pool to query
/// @return Dictionary with deposits, savingsEarned (totalEarnedPrizes always 0 for sponsors)
access(all) fun main(sponsorAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(sponsorAddress)
    
    if let collection = account.capabilities.borrow<&PrizeSavings.SponsorPositionCollection>(
        PrizeSavings.SponsorPositionCollectionPublicPath
    ) {
        let balance = collection.getPoolBalance(poolID: poolID)
        return {
            "deposits": balance.deposits,
            "totalEarnedPrizes": balance.totalEarnedPrizes,
            "savingsEarned": balance.savingsEarned
        }
    }
    
    return {
        "deposits": 0.0,
        "totalEarnedPrizes": 0.0,
        "savingsEarned": 0.0
    }
}

