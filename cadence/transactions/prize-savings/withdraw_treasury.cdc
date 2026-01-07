import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Withdraw Treasury transaction - Withdraws unclaimed treasury funds from pool (Admin only)
/// Treasury funds come from the treasury percentage of yield distribution when no recipient is set.
///
/// Parameters:
/// - poolID: The ID of the pool to withdraw treasury from
/// - amount: The amount to withdraw
/// - purpose: A description of why the funds are being withdrawn (for logging)
transaction(poolID: UInt64, amount: UFix64, purpose: String) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let receiverCap: Capability<&{FungibleToken.Receiver}>
    
    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
        
        // Get or create a receiver capability
        self.receiverCap = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        if !self.receiverCap.check() {
            panic("FlowToken receiver capability not found or invalid")
        }
    }
    
    execute {
        // Withdraw from treasury - function deposits directly via capability
        let withdrawnAmount = self.adminRef.withdrawUnclaimedTreasury(
            poolID: poolID,
            amount: amount,
            recipient: self.receiverCap
        )
        
        log("Withdrew ".concat(withdrawnAmount.toString()).concat(" from pool ").concat(poolID.toString()).concat(" treasury for: ").concat(purpose))
    }
}
