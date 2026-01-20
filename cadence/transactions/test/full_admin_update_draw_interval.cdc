import "PrizeLinkedAccounts"

/// Full admin delegate uses both entitlements to update draw interval for future rounds (ConfigOps function)
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the full admin capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminFull
        ) ?? panic("No full admin capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow full admin reference")
        
        adminRef.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Full admin delegate updated draw interval for pool ".concat(poolID.toString()))
    }
}
