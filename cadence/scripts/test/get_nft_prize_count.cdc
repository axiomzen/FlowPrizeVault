import "PrizeLinkedAccounts"

/// Get the count of available NFT prizes in a pool
access(all) fun main(poolID: UInt64): Int {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return pool.getAvailableNFTPrizeIDs().length
}
