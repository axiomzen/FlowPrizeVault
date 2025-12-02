import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Setup Test Yield Vault - Creates a dedicated vault for yield testing
/// This vault will receive deposits and can provide withdrawals (simulating a yield source)
/// The admin will fund this vault to simulate yield generation
///
/// Stores at: /storage/testYieldVault
/// Provider capability at: /storage/testYieldVaultProvider (private)
/// Receiver capability at: /public/testYieldVaultReceiver
transaction {
    
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if vault already exists
        if signer.storage.borrow<&FlowToken.Vault>(from: /storage/testYieldVault) != nil {
            log("Test yield vault already exists")
            return
        }
        
        // Create and store a new vault for yield testing
        let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-vault, to: /storage/testYieldVault)
        
        // Issue provider capability (for withdrawing - simulating yield returns)
        let providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(
            /storage/testYieldVault
        )
        
        // Issue receiver capability (for depositing into yield source)
        let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(
            /storage/testYieldVault
        )
        signer.capabilities.publish(receiverCap, at: /public/testYieldVaultReceiver)
        
        log("Test yield vault created successfully")
        log("Provider capability ID: ".concat(providerCap.id.toString()))
    }
    
    execute {
        log("Test yield vault setup complete!")
    }
}

