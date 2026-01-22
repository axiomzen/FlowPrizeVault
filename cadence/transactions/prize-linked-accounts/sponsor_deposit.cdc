import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"

/// Deposits funds as a sponsor (prize-ineligible).
/// 
/// Sponsors earn rewards yield through share price appreciation but
/// are NOT eligible to win prize prizes.
/// 
/// Prerequisites:
/// - Must have called setup_sponsor_collection first
/// - Must have sufficient FlowToken balance
/// 
/// @param poolID - ID of the pool to deposit into
/// @param amount - Amount of FlowToken to deposit
transaction(poolID: UInt64, amount: UFix64) {
    let collection: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.SponsorPositionCollection
    let vault: @{FungibleToken.Vault}
    
    prepare(signer: auth(BorrowValue) &Account) {
        // Get sponsor collection reference
        self.collection = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.SponsorPositionCollection>(
            from: PrizeLinkedAccounts.SponsorPositionCollectionStoragePath
        ) ?? panic("No SponsorPositionCollection found. Run setup_sponsor_collection first.")
        
        // Withdraw funds from FlowToken vault
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("No FlowToken vault found")
        
        self.vault <- flowVault.withdraw(amount: amount)
    }
    
    execute {
        self.collection.deposit(poolID: poolID, from: <- self.vault)
        log("Successfully deposited ".concat(amount.toString()).concat(" as sponsor into pool ").concat(poolID.toString()))
    }
}

