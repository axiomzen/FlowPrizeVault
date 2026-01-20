import "PrizeLinkedAccounts"

/// Transaction to disable emergency mode on a pool
transaction(poolID: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.disableEmergencyMode(poolID: poolID)
        
        log("Emergency mode disabled for pool ".concat(poolID.toString()))
    }
}

