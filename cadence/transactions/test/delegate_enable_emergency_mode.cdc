import "PrizeSavings"

/// Delegate uses CriticalOps capability to enable emergency mode
transaction(poolID: UInt64, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        adminRef.enableEmergencyMode(
            poolID: poolID,
            reason: reason
        )
        
        log("Delegate enabled emergency mode for pool ".concat(poolID.toString()))
    }
}
