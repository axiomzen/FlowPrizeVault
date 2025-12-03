import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Setup transaction - Creates and stores a PoolPositionCollection for PrizeSavings
/// Users only need to run this once before interacting with any pools
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.borrow<&PrizeSavings.PoolPositionCollection>(
            from: PrizeSavings.PoolPositionCollectionStoragePath
        ) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and store the collection
        let collection <- PrizeSavings.createPoolPositionCollection()
        signer.storage.save(
            <-collection,
            to: PrizeSavings.PoolPositionCollectionStoragePath
        )
        
        // Link public capability with public interface
        let cap = signer.capabilities.storage.issue<&{PrizeSavings.PoolPositionCollectionPublic}>(
            PrizeSavings.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(
            cap,
            at: PrizeSavings.PoolPositionCollectionPublicPath
        )
        
        log("PoolPositionCollection created and stored")
    }
    
    execute {
        log("Setup complete!")
    }
}

