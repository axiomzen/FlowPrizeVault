import "PrizeSavings"

/// Get a user's balance and prize stats in a pool
/// Note: totalEarnedPrizes is a cumulative stat - prizes are REINVESTED
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)
    
    let collectionRef = account.capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    
    return {
        "totalBalance": balance.totalBalance,
        "totalEarnedPrizes": balance.totalEarnedPrizes
    }
}
