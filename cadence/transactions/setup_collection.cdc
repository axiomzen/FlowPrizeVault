import PrizeVault from "../contracts/PrizeVault.cdc"

/// Setup transaction - Creates and stores a PoolPositionCollection
/// Users only need to run this once
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.borrow<&PrizeVault.PoolPositionCollection>(
            from: PrizeVault.PoolPositionCollectionStoragePath
        ) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and store the collection
        let collection <- PrizeVault.createPoolPositionCollection()
        signer.storage.save(
            <-collection,
            to: PrizeVault.PoolPositionCollectionStoragePath
        )
        
        // Link public capability with public interface
        let cap = signer.capabilities.storage.issue<&{PrizeVault.PoolPositionCollectionPublic}>(
            PrizeVault.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(
            cap,
            at: PrizeVault.PoolPositionCollectionPublicPath
        )
        
        log("PoolPositionCollection created and stored")
    }
    
    execute {
        log("Setup complete!")
    }
}

