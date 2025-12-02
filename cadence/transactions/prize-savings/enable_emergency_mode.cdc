import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Enable Emergency Mode transaction - Enables emergency mode for a pool (Admin only)
/// In emergency mode, only withdrawals are allowed (no deposits or draws)
///
/// Parameters:
/// - poolID: The ID of the pool
/// - reason: The reason for enabling emergency mode
transaction(poolID: UInt64, reason: String) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let signerAddress: Address
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.signerAddress = signer.address
        
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.enableEmergencyMode(
            poolID: poolID,
            reason: reason,
            enabledBy: self.signerAddress
        )
        
        log("Emergency mode enabled for pool ".concat(poolID.toString()))
    }
}

