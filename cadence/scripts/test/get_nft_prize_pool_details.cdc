import "PrizeLinkedAccounts"

/// Get NFT prize pool details
access(all) fun main(poolID: UInt64): {String: AnyStruct} {
    let pool = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    let availableNFTIDs = pool.getAvailableNFTPrizeIDs()

    return {
        "poolID": poolID,
        "nftPrizeCount": availableNFTIDs.length,
        "availableNFTIDs": availableNFTIDs
    }
}
