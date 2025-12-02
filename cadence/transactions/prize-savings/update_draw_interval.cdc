import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Update Draw Interval transaction - Changes the time between lottery draws (Admin only)
///
/// Parameters:
/// - poolID: The ID of the pool to update
/// - newInterval: The new draw interval in seconds (e.g., 86400.0 for daily)
transaction(poolID: UInt64, newInterval: UFix64) {
    
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    let signerAddress: Address
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.signerAddress = signer.address
        
        // Borrow the Admin resource with ConfigOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.updatePoolDrawInterval(
            poolID: poolID,
            newInterval: newInterval,
            updatedBy: self.signerAddress
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()).concat(" to ").concat(newInterval.toString()).concat(" seconds"))
    }
}

