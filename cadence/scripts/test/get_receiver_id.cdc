import "PrizeLinkedAccounts"

/// Get a user's receiver ID (PoolPositionCollection UUID) for a pool
access(all) fun main(userAddress: Address, poolID: UInt64): UInt64 {
    let account = getAccount(userAddress)

    let collectionRef = account
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        ) ?? panic("Could not borrow PoolPositionCollection public reference")

    return collectionRef.uuid
}
