import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Disable Emergency Mode transaction - Disables emergency mode for a pool (Admin only)
/// Returns the pool to normal operation
///
/// Parameters:
/// - poolID: The ID of the pool
transaction(poolID: UInt64) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.disableEmergencyMode(poolID: poolID)
        
        log("Emergency mode disabled for pool ".concat(poolID.toString()))
    }
}

