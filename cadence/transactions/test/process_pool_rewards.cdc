import "PrizeSavings"

/// Transaction to process rewards for a pool
transaction(poolID: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.processPoolRewards(poolID: poolID)
        
        log("Processed rewards for pool ".concat(poolID.toString()))
    }
}

