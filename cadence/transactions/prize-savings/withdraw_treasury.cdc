import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Withdraw Treasury transaction - Withdraws funds from the pool treasury (Admin only)
/// Treasury funds come from the treasury percentage of yield distribution
///
/// Parameters:
/// - poolID: The ID of the pool to withdraw treasury from
/// - amount: The amount to withdraw
/// - purpose: A description of why the funds are being withdrawn
transaction(poolID: UInt64, amount: UFix64, purpose: String) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
        
        // Borrow the receiver vault
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken receiver")
    }
    
    execute {
        // Withdraw from treasury
        let withdrawn <- self.adminRef.withdrawPoolTreasury(
            poolID: poolID,
            amount: amount,
            purpose: purpose
        )
        
        let withdrawnAmount = withdrawn.balance
        
        // Deposit to admin's vault
        self.receiverRef.deposit(from: <-withdrawn)
        
        log("Withdrew ".concat(withdrawnAmount.toString()).concat(" from pool ").concat(poolID.toString()).concat(" treasury"))
    }
}

