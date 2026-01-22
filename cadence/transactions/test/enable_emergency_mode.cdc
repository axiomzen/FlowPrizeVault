import "PrizeLinkedAccounts"

/// Transaction to enable emergency mode on a pool
transaction(poolID: UInt64, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.enableEmergencyMode(poolID: poolID, reason: reason)
        
        log("Emergency mode enabled for pool ".concat(poolID.toString()))
    }
}

