import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Add Yield to Pool Vault - Deposits funds to a specific pool's test yield vault
/// to simulate yield appreciation
///
/// This is for testing the excess handling logic in syncWithYieldSource()
///
/// Parameters:
/// - poolIndex: The index of the pool's yield vault (matches pool creation order)
/// - amount: Amount of FLOW to add as simulated yield
/// - vaultPrefix: The prefix used for the vault path (e.g., "testYieldVault_" or "testYieldVaultDist_")
transaction(poolIndex: Int, amount: UFix64, vaultPrefix: String) {
    
    let senderVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Get sender's main FLOW vault
        self.senderVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow sender's FlowToken vault")
        
        // Construct the storage path for this pool's yield vault
        let vaultPath = StoragePath(identifier: vaultPrefix.concat(poolIndex.toString()))!
        
        // Get the yield vault receiver
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: vaultPath
        ) ?? panic("Could not borrow yield vault at path: ".concat(vaultPath.toString()))
    }
    
    execute {
        let tokens <- self.senderVault.withdraw(amount: amount)
        self.receiverRef.deposit(from: <- tokens)
        
        log("Added ".concat(amount.toString()).concat(" FLOW as simulated yield to pool ".concat(poolIndex.toString())))
    }
}
