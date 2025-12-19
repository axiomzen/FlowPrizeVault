import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Simulate Yield Depreciation - Withdraws funds from the test yield vault
/// to simulate a decrease in underlying asset value (e.g., slashing, impermanent loss)
///
/// This is for testing the deficit handling logic in syncWithYieldSource()
///
/// Parameters:
/// - poolIndex: The index of the pool's yield vault (matches pool creation order)
/// - amount: Amount of FLOW to withdraw from the yield vault
/// - vaultPrefix: The prefix used for the vault path (e.g., "testYieldVault_" or "testYieldVaultDist_")
transaction(poolIndex: Int, amount: UFix64, vaultPrefix: String) {
    
    let yieldVaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Construct the storage path for this pool's yield vault
        let vaultPath = StoragePath(identifier: vaultPrefix.concat(poolIndex.toString()))!
        
        // Borrow the yield vault with withdraw permission
        self.yieldVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: vaultPath
        ) ?? panic("Could not borrow yield vault at path: ".concat(vaultPath.toString()))
        
        // Get signer's main vault to receive the withdrawn funds
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow receiver vault")
    }
    
    execute {
        // Withdraw from yield vault (simulating value decrease)
        let tokens <- self.yieldVaultRef.withdraw(amount: amount)
        
        // Deposit back to signer's main vault
        self.receiverRef.deposit(from: <- tokens)
        
        log("Simulated depreciation of ".concat(amount.toString()).concat(" FLOW from yield vault"))
    }
}
