import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Setup transaction - Creates and stores a PoolPositionCollection for PrizeVaultModular
/// Users only need to run this once
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.borrow<&PrizeVaultModular.PoolPositionCollection>(
            from: PrizeVaultModular.PoolPositionCollectionStoragePath
        ) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and store the collection
        let collection <- PrizeVaultModular.createPoolPositionCollection()
        signer.storage.save(
            <-collection,
            to: PrizeVaultModular.PoolPositionCollectionStoragePath
        )
        
        // Link public capability with public interface
        let cap = signer.capabilities.storage.issue<&{PrizeVaultModular.PoolPositionCollectionPublic}>(
            PrizeVaultModular.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(
            cap,
            at: PrizeVaultModular.PoolPositionCollectionPublicPath
        )
        
        log("PoolPositionCollection created and stored")
    }
    
    execute {
        log("Setup complete!")
    }
}

