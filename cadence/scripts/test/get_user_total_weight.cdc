import "PrizeLinkedAccounts"

/// Get user's TWAB weight for a pool (bonus weight is handled separately in draws)
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    let account = getAccount(userAddress)

    let collectionRef = account
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        ) ?? panic("Could not borrow PoolPositionCollection public reference")

    // Get the user's entries (TWAB-based weight)
    return collectionRef.getPoolEntries(poolID: poolID)
}
