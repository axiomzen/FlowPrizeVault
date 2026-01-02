import "FungibleToken"
import "FlowToken"

/// Mints FLOW tokens directly to an account (service account only)
/// This bypasses the balance limitation of the service account for extreme test scenarios
transaction(recipient: Address, amount: UFix64) {
    let tokenAdmin: &FlowToken.Administrator
    let recipientVault: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the FlowToken Administrator resource
        self.tokenAdmin = signer.storage.borrow<&FlowToken.Administrator>(
            from: /storage/flowTokenAdmin
        ) ?? panic("Could not borrow FlowToken.Administrator")

        // Get the recipient's receiver capability
        self.recipientVault = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver reference")
    }

    execute {
        // Create a minter and mint tokens
        let minter <- self.tokenAdmin.createNewMinter(allowedAmount: amount)
        let mintedVault <- minter.mintTokens(amount: amount)
        
        // Deposit to recipient
        self.recipientVault.deposit(from: <-mintedVault)
        
        destroy minter
    }
}

