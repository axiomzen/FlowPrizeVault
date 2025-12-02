import "FungibleToken"
import "FlowToken"

/// Transfer FlowToken from signer to a recipient address
/// Used for funding test accounts
transaction(recipient: Address, amount: UFix64) {
    
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the vault to withdraw from
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault from signer")
        
        // Get the recipient's receiver capability
        let recipientAccount = getAccount(recipient)
        self.receiverRef = recipientAccount.capabilities.borrow<&{FungibleToken.Receiver}>(
            /public/flowTokenReceiver
        ) ?? panic("Could not borrow receiver reference from recipient")
    }
    
    execute {
        // Withdraw and deposit
        let tokens <- self.vaultRef.withdraw(amount: amount)
        self.receiverRef.deposit(from: <-tokens)
        
        log("Transferred ".concat(amount.toString()).concat(" FLOW to ").concat(recipient.toString()))
    }
}

