import "PrizeLinkedAccounts"

/// Request randomness after batch processing is complete (Admin only)
transaction(poolID: UInt64) {
    
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.requestPoolDrawRandomness(poolID: poolID)
        log("Randomness requested for pool ".concat(poolID.toString()))
    }
}
