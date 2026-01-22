import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"

/// Deposit tokens into a PrizeLinkedAccounts pool
/// Auto-registers with the pool on first deposit
transaction(poolID: UInt64, amount: UFix64) {
    
    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection with Withdraw entitlement for deposit
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found. Run setup_user_collection.cdc first")
        
        // Borrow the vault to withdraw from
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }
    
    execute {
        // Withdraw tokens from vault
        let tokens <- self.vaultRef.withdraw(amount: amount)
        
        // Deposit into the pool (auto-registers if first time)
        self.collectionRef.deposit(poolID: poolID, from: <-tokens)
        
        log("Successfully deposited ".concat(amount.toString()).concat(" tokens into pool ").concat(poolID.toString()))
    }
}

