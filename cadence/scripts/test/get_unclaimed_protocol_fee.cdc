import "PrizeLinkedAccounts"

/// Get the unclaimed protocol fee balance for a pool
access(all) fun main(poolID: UInt64): UFix64 {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return pool.getUnclaimedProtocolBalance()
}
