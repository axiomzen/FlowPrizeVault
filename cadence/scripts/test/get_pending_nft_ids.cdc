import "PrizeLinkedAccounts"

/// Get the IDs of pending NFT claims for a user
access(all) fun main(userAddress: Address, poolID: UInt64): [UInt64] {
    let account = getAccount(userAddress)

    let collectionRef = account
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        )

    if collectionRef == nil {
        return []
    }

    return collectionRef!.getPendingNFTIDs(poolID: poolID)
}
