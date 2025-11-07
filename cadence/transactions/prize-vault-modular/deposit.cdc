import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Deposit transaction - Deposits tokens into a specific modular pool
/// Auto-registers with the pool on first deposit
///
/// Parameters:
/// - poolID: The ID of the pool to deposit into
/// - amount: The amount of tokens to deposit
transaction(poolID: UInt64, amount: UFix64) {
    
    let collectionRef: &PrizeVaultModular.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection
        self.collectionRef = signer.storage.borrow<&PrizeVaultModular.PoolPositionCollection>(
            from: PrizeVaultModular.PoolPositionCollectionStoragePath
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

