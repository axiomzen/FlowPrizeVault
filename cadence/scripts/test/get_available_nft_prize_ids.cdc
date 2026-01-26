import "PrizeLinkedAccounts"

/// Get the available NFT prize IDs in a pool
access(all) fun main(poolID: UInt64): [UInt64] {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return pool.getAvailableNFTPrizeIDs()
}
