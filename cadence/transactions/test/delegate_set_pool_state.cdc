import "PrizeLinkedAccounts"

/// Delegate uses CriticalOps capability to set pool state
transaction(poolID: UInt64, state: UInt8, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminCriticalOps
        ) ?? panic("No CriticalOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow CriticalOps admin reference")
        
        adminRef.setPoolState(
            poolID: poolID,
            state: PrizeLinkedAccounts.PoolEmergencyState(rawValue: state)!,
            reason: reason
        )
        
        log("Delegate set pool state for pool ".concat(poolID.toString()))
    }
}
