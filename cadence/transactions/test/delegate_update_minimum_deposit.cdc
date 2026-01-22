import "PrizeLinkedAccounts"

/// Delegate uses ConfigOps capability to update minimum deposit
transaction(poolID: UInt64, newMinimum: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the capability from own storage
        let cap = signer.storage.borrow<&Capability<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>>(
            from: /storage/PrizeLinkedAccountsAdminConfigOps
        ) ?? panic("No ConfigOps capability found in storage")
        
        let adminRef = cap.borrow()
            ?? panic("Could not borrow ConfigOps admin reference")
        
        adminRef.updatePoolMinimumDeposit(
            poolID: poolID,
            newMinimum: newMinimum
        )
        
        log("Delegate updated minimum deposit for pool ".concat(poolID.toString()))
    }
}
