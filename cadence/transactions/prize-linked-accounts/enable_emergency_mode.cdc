import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Enable Emergency Mode transaction - Enables emergency mode for a pool (Admin only)
/// In emergency mode, only withdrawals are allowed (no deposits or draws)
///
/// Parameters:
/// - poolID: The ID of the pool
/// - reason: The reason for enabling emergency mode
transaction(poolID: UInt64, reason: String) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.enableEmergencyMode(
            poolID: poolID,
            reason: reason
        )
        
        log("Emergency mode enabled for pool ".concat(poolID.toString()))
    }
}

