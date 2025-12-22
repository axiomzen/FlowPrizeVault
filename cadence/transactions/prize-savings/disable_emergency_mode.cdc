import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Disable Emergency Mode transaction - Disables emergency mode for a pool (Admin only)
/// Returns the pool to normal operation
///
/// Parameters:
/// - poolID: The ID of the pool
transaction(poolID: UInt64) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.disableEmergencyMode(poolID: poolID)
        
        log("Emergency mode disabled for pool ".concat(poolID.toString()))
    }
}

