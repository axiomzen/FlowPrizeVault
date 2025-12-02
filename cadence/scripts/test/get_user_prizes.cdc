import "PrizeSavings"

/// Get a user's balance and prize stats in a pool
/// Note: totalEarnedPrizes is a cumulative stat - prizes are REINVESTED into deposits
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)
    
    let collectionRef = account.capabilities.borrow<&{PrizeSavings.PoolPositionCollectionPublic}>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    
    // Note: deposits already includes reinvested prize winnings
    // totalEarnedPrizes is just a stat tracking cumulative prizes won
    // Actual withdrawable = deposits + savingsEarned
    return {
        "deposits": balance.deposits,
        "totalEarnedPrizes": balance.totalEarnedPrizes,
        "savingsEarned": balance.savingsEarned,
        "withdrawableBalance": balance.deposits + balance.savingsEarned
    }
}

