import "PrizeSavings"

/// Delegate uses ConfigOps capability to update draw interval for future rounds
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminConfigOps
        ) ?? panic("No ConfigOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow ConfigOps admin reference")
        
        adminRef.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Delegate updated draw interval for pool ".concat(poolID.toString()))
    }
}
