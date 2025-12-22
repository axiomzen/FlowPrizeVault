import "PrizeSavings"

/// Transaction to update the winner selection strategy to include NFT IDs
/// This allows NFTs deposited to the pool to be awarded during lottery draws
transaction(poolID: UInt64, nftIDs: [UInt64]) {
    prepare(signer: auth(Storage) &Account) {
        // Borrow admin resource
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Create new winner selection strategy with NFT IDs
        let newStrategy = PrizeSavings.WeightedSingleWinner(
            nftIDs: nftIDs
        ) as {PrizeSavings.WinnerSelectionStrategy}
        
        // Update the pool's winner selection strategy
        admin.updatePoolWinnerSelectionStrategy(
            poolID: poolID,
            newStrategy: newStrategy
        )
        
        log("Updated winner selection strategy with ".concat(nftIDs.length.toString()).concat(" NFT IDs"))
    }
}

