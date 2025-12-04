import "PrizeSavings"

/// Transaction to enable emergency mode on a pool
transaction(poolID: UInt64, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.enableEmergencyMode(poolID: poolID, reason: reason, enabledBy: signer.address)
        
        log("Emergency mode enabled for pool ".concat(poolID.toString()))
    }
}

