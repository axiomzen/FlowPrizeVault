import "PrizeSavings"

/// Full admin delegate uses both entitlements to update draw interval (ConfigOps function)
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the full admin capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.ConfigOps, PrizeSavings.CriticalOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminFull
        ) ?? panic("No full admin capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow full admin reference")
        
        adminRef.updatePoolDrawInterval(
            poolID: poolID,
            newInterval: newInterval,
            updatedBy: signer.address
        )
        
        log("Full admin delegate updated draw interval for pool ".concat(poolID.toString()))
    }
}
