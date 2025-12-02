import "PrizeSavings"
import "FungibleToken"
import "FlowToken"

/// Fund the lottery prize pool directly using Admin
/// This simulates yield that would go to the lottery
transaction(poolID: UInt64, amount: UFix64) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Borrow FlowToken vault
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }
    
    execute {
        // Withdraw tokens
        let tokens <- self.vaultRef.withdraw(amount: amount)
        
        // Fund the lottery pool directly
        self.adminRef.fundPoolDirect(
            poolID: poolID,
            destination: PrizeSavings.PoolFundingDestination.Lottery,
            from: <- tokens,
            sponsor: self.vaultRef.owner!.address,
            purpose: "Test funding",
            metadata: nil
        )
        
        log("Funded lottery pool with ".concat(amount.toString()).concat(" FLOW"))
    }
}

