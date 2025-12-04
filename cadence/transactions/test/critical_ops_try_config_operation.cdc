import "PrizeSavings"

/// Attempt to use CriticalOps capability to call a ConfigOps function (should fail)
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the CriticalOps capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        // This should fail at runtime because updatePoolDrawInterval requires ConfigOps
        // but we only have CriticalOps
        adminRef.updatePoolDrawInterval(
            poolID: poolID,
            newInterval: newInterval,
            updatedBy: signer.address
        )
    }
}
