import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Deposit transaction - Deposits FLOW tokens into a specific PrizeSavings pool
/// Auto-registers with the pool on first deposit
///
/// Parameters:
/// - poolID: The ID of the pool to deposit into
/// - amount: The amount of FLOW tokens to deposit
transaction(poolID: UInt64, amount: UFix64) {
    
    let collectionRef: &PrizeSavings.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection
        self.collectionRef = signer.storage.borrow<&PrizeSavings.PoolPositionCollection>(
            from: PrizeSavings.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found. Run setup_collection.cdc first")
        
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

