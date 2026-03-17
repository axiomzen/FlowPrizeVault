import "PrizeLinkedAccounts"

/// Fork-test: Get user's projected balance in a pool.
/// Returns the projected asset value accounting for unsync'd yield or deficit.
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    let account = getAccount(userAddress)
    let collectionRef = account.capabilities.borrow<&{PrizeLinkedAccounts.PoolPositionCollectionPublic}>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    )

    if collectionRef == nil {
        return 0.0
    }

    let receiverID = collectionRef!.uuid
    return PrizeLinkedAccounts.getProjectedUserBalance(poolID: poolID, receiverID: receiverID)
}
