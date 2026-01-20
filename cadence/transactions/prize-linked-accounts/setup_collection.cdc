import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Setup transaction - Creates and stores a PoolPositionCollection for PrizeLinkedAccounts
/// Users only need to run this once before interacting with any pools
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.type(at: PrizeLinkedAccounts.PoolPositionCollectionStoragePath) != nil {
            log("Collection already exists")
            return
        }
        
        // Create and store the collection
        let collection <- PrizeLinkedAccounts.createPoolPositionCollection()
        signer.storage.save(
            <-collection,
            to: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        )
        
        // Link public capability with public interface
        let cap = signer.capabilities.storage.issue<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        )
        signer.capabilities.publish(
            cap,
            at: PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        )
        
        log("PoolPositionCollection created and stored")
    }
    
    execute {
        log("Setup complete!")
    }
}

