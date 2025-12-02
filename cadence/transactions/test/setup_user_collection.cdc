import "PrizeSavings"

/// Set up a PoolPositionCollection for a user
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.borrow<&PrizeSavings.PoolPositionCollection>(
            from: PrizeSavings.PoolPositionCollectionStoragePath
        ) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and save the collection
        let collection <- PrizeSavings.createPoolPositionCollection()
        signer.storage.save(<-collection, to: PrizeSavings.PoolPositionCollectionStoragePath)
        
        // Create public capability
        let cap = signer.capabilities.storage.issue<&{PrizeSavings.PoolPositionCollectionPublic}>(
            PrizeSavings.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(cap, at: PrizeSavings.PoolPositionCollectionPublicPath)
        
        log("Collection created successfully")
    }
}

