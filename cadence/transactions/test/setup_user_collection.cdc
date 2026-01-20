import "PrizeLinkedAccounts"

/// Set up a PoolPositionCollection for a user
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.type(at: PrizeLinkedAccounts.PoolPositionCollectionStoragePath) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and save the collection
        let collection <- PrizeLinkedAccounts.createPoolPositionCollection()
        signer.storage.save(<-collection, to: PrizeLinkedAccounts.PoolPositionCollectionStoragePath)
        
        // Create public capability
        let cap = signer.capabilities.storage.issue<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(cap, at: PrizeLinkedAccounts.PoolPositionCollectionPublicPath)
        
        log("Collection created successfully")
    }
}

