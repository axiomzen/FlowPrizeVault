import "PrizeSavings"

/// Delegate uses ConfigOps capability to process pool rewards
transaction(poolID: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminConfigOps
        ) ?? panic("No ConfigOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow ConfigOps admin reference")
        
        adminRef.processPoolRewards(poolID: poolID)
        
        log("Delegate processed rewards for pool ".concat(poolID.toString()))
    }
}
