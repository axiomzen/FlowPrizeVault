import "PrizeLinkedAccounts"

/// Delegate uses CriticalOps capability to update distribution strategy
transaction(poolID: UInt64, rewards: UFix64, prize: UFix64, protocolFee: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        let newStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewards,
            prize: prize,
            protocolFee: protocolFee
        )
        
        adminRef.updatePoolDistributionStrategy(
            poolID: poolID,
            newStrategy: newStrategy
        )
        
        log("Delegate updated distribution strategy for pool ".concat(poolID.toString()))
    }
}
