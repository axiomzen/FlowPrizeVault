import "PrizeLinkedAccounts"

/// Transaction to update the prize distribution to include NFT IDs
/// This allows NFTs deposited to the pool to be awarded during lottery draws
transaction(poolID: UInt64, nftIDs: [UInt64]) {
    prepare(signer: auth(Storage) &Account) {
        // Borrow admin resource
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Create new prize distribution with NFT IDs
        let newDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: nftIDs
        ) as {PrizeLinkedAccounts.PrizeDistribution}
        
        // Update the pool's prize distribution
        admin.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )
        
        log("Updated prize distribution with ".concat(nftIDs.length.toString()).concat(" NFT IDs"))
    }
}

