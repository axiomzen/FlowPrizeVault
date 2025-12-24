import "PrizeSavings"

/// Sets up a SponsorPositionCollection for the signer.
/// 
/// This enables the account to make sponsor deposits (lottery-ineligible).
/// Sponsors earn savings yield but cannot win lottery prizes.
/// 
/// A single account can have both a PoolPositionCollection (lottery-eligible)
/// AND a SponsorPositionCollection (lottery-ineligible) simultaneously.
transaction {
    prepare(signer: auth(SaveValue, BorrowValue, Capabilities) &Account) {
        // Check if already exists
        if signer.storage.borrow<&PrizeSavings.SponsorPositionCollection>(
            from: PrizeSavings.SponsorPositionCollectionStoragePath
        ) != nil {
            log("SponsorPositionCollection already exists")
            return
        }
        
        // Create and save
        let collection <- PrizeSavings.createSponsorPositionCollection()
        signer.storage.save(<- collection, to: PrizeSavings.SponsorPositionCollectionStoragePath)
        
        // Issue and publish public capability for scripts to access
        let cap = signer.capabilities.storage.issue<&PrizeSavings.SponsorPositionCollection>(
            PrizeSavings.SponsorPositionCollectionStoragePath
        )
        signer.capabilities.publish(cap, at: PrizeSavings.SponsorPositionCollectionPublicPath)
        
        log("SponsorPositionCollection created successfully")
    }
}

