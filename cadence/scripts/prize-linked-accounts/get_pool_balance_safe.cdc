import "PrizeLinkedAccounts"

/// Returns a user's withdrawable balance in a pool, or 0.0 if the account has no
/// collection / is not registered. Safe to run at historical block heights where
/// the account may not yet have set up a collection.
access(all) fun main(address: Address, poolID: UInt64): UFix64 {
    let col = getAccount(address).capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    )
    if col == nil { return 0.0 }
    return col!.getPoolBalance(poolID: poolID).totalBalance
}
