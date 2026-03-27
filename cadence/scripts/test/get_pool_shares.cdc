import "PrizeLinkedAccounts"

/// Returns total outstanding shares for a pool's share tracker.
access(all) fun main(poolID: UInt64): UFix64 {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    return poolRef.getTotalRewardsShares()
}
