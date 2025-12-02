import "PrizeSavings"

/// Get a user's balance in a specific pool
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)
    
    let collectionRef = account.capabilities.borrow<&{PrizeSavings.PoolPositionCollectionPublic}>(
        PrizeSavings.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")
    
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    
    return {
        "deposits": balance.deposits,
        "totalEarnedPrizes": balance.totalEarnedPrizes,
        "savingsEarned": balance.savingsEarned
    }
}

