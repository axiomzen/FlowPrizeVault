import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"

/// Withdraws funds from a sponsor position.
/// 
/// Sponsors can withdraw their deposits plus any earned savings yield.
/// 
/// @param poolID - ID of the pool to withdraw from
/// @param amount - Amount to withdraw
transaction(poolID: UInt64, amount: UFix64) {
    let collection: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.SponsorPositionCollection
    let flowVault: &FlowToken.Vault
    
    prepare(signer: auth(BorrowValue) &Account) {
        // Get sponsor collection reference
        self.collection = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.SponsorPositionCollection>(
            from: PrizeLinkedAccounts.SponsorPositionCollectionStoragePath
        ) ?? panic("No SponsorPositionCollection found")
        
        // Get FlowToken vault to receive funds
        self.flowVault = signer.storage.borrow<&FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("No FlowToken vault found")
    }
    
    execute {
        let withdrawn <- self.collection.withdraw(poolID: poolID, amount: amount)
        let actualAmount = withdrawn.balance
        self.flowVault.deposit(from: <- withdrawn)
        log("Successfully withdrew ".concat(actualAmount.toString()).concat(" from sponsor position in pool ").concat(poolID.toString()))
    }
}

