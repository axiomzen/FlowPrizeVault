import "PrizeLinkedAccounts"

/// Get a user's bonus weight for a pool
access(all) fun main(poolID: UInt64, receiverID: UInt64): UFix64 {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return pool.getBonusWeight(receiverID: receiverID)
}
