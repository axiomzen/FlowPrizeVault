import "PrizeLinkedAccounts"

/// Attempt to use ConfigOps capability to call a CriticalOps function (should fail)
transaction(poolID: UInt64, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get the ConfigOps capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminConfigOps
        ) ?? panic("No ConfigOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow ConfigOps admin reference")
        
        // This should fail at runtime because enableEmergencyMode requires CriticalOps
        // but we only have ConfigOps
        adminRef.enableEmergencyMode(
            poolID: poolID,
            reason: reason
        )
    }
}
