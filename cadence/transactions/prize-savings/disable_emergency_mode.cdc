import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Disable Emergency Mode transaction - Disables emergency mode for a pool (Admin only)
/// Returns the pool to normal operation
///
/// Parameters:
/// - poolID: The ID of the pool
transaction(poolID: UInt64) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let signerAddress: Address
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.signerAddress = signer.address
        
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.disableEmergencyMode(
            poolID: poolID,
            disabledBy: self.signerAddress
        )
        
        log("Emergency mode disabled for pool ".concat(poolID.toString()))
    }
}

