import "PrizeSavings"

/// Delegate uses CriticalOps capability to set pool state
transaction(poolID: UInt64, state: UInt8, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        adminRef.setPoolState(
            poolID: poolID,
            state: PrizeSavings.PoolEmergencyState(rawValue: state)!,
            reason: reason,
            setBy: signer.address
        )
        
        log("Delegate set pool state for pool ".concat(poolID.toString()))
    }
}
