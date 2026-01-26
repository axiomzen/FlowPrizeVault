import "PrizeLinkedAccounts"

/// Get the count of pending NFT claims for a user
access(all) fun main(userAddress: Address, poolID: UInt64): Int {
    let account = getAccount(userAddress)

    let collectionRef = account
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        )

    if collectionRef == nil {
        return 0
    }

    return collectionRef!.getPendingNFTCount(poolID: poolID)
}
