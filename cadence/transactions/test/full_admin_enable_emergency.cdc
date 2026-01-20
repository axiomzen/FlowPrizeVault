import "PrizeLinkedAccounts"

/// Full admin delegate uses both entitlements to enable emergency mode (CriticalOps function)
transaction(poolID: UInt64, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get the full admin capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminFull
        ) ?? panic("No full admin capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow full admin reference")
        
        adminRef.enableEmergencyMode(
            poolID: poolID,
            reason: reason
        )
        
        log("Full admin delegate enabled emergency mode for pool ".concat(poolID.toString()))
    }
}
