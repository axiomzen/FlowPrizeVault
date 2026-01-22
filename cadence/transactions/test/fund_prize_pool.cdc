import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"

/// Fund the prize prize pool directly using Admin
/// This simulates yield that would go to the prize
transaction(poolID: UInt64, amount: UFix64) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Borrow FlowToken vault
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }
    
    execute {
        // Withdraw tokens
        let tokens <- self.vaultRef.withdraw(amount: amount)
        
        // Fund the prize pool directly
        self.adminRef.fundPoolDirect(
            poolID: poolID,
            destination: PrizeLinkedAccounts.PoolFundingDestination.Prize,
            from: <- tokens,
            purpose: "Test funding",
            metadata: nil
        )
        
        log("Funded prize pool with ".concat(amount.toString()).concat(" FLOW"))
    }
}

