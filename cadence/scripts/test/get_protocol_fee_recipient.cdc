import "PrizeLinkedAccounts"

/// Get protocol fee recipient address for a pool (nil if not set)
access(all) fun main(poolID: UInt64): Address? {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return pool.getProtocolRecipient()
}
