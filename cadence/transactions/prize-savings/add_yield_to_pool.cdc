import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Add Yield to Pool - Simulates yield generation by adding funds to the test yield vault
/// This is for testing purposes - the funds added will be available as "yield"
/// when processRewards is called
///
/// Parameters:
/// - amount: Amount of FLOW to add as simulated yield
transaction(amount: UFix64) {
    
    let senderVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Get sender's main FLOW vault
        self.senderVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow sender's FlowToken vault")
        
        // Get test yield vault receiver
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: /storage/testYieldVault
        ) ?? panic("Could not borrow test yield vault - run setup_test_yield_vault.cdc first")
    }
    
    execute {
        let tokens <- self.senderVault.withdraw(amount: amount)
        self.receiverRef.deposit(from: <- tokens)
        
        log("Added ".concat(amount.toString()).concat(" FLOW as simulated yield"))
    }
}

