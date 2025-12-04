import "PrizeSavings"

/// Delegate uses CriticalOps capability to update distribution strategy
transaction(poolID: UInt64, savings: UFix64, lottery: UFix64, treasury: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>>(
            from: /storage/PrizeSavingsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        let newStrategy = PrizeSavings.FixedPercentageStrategy(
            savings: savings,
            lottery: lottery,
            treasury: treasury
        )
        
        adminRef.updatePoolDistributionStrategy(
            poolID: poolID,
            newStrategy: newStrategy,
            updatedBy: signer.address
        )
        
        log("Delegate updated distribution strategy for pool ".concat(poolID.toString()))
    }
}
