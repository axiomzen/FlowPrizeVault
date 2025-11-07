import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Transfer FLOW tokens from one account to another
///
/// Parameters:
/// - recipient: The address to send tokens to
/// - amount: The amount of FLOW to send
transaction(recipient: Address, amount: UFix64) {
    
    let senderVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Get sender's vault
        self.senderVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow sender's FlowToken vault")
        
        // Get receiver's public receiver
        self.receiverRef = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver's FlowToken receiver")
    }
    
    execute {
        let tokens <- self.senderVault.withdraw(amount: amount)
        self.receiverRef.deposit(from: <- tokens)
        
        log("Transferred ".concat(amount.toString()).concat(" FLOW to ").concat(recipient.toString()))
    }
}

