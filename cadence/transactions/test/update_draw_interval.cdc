import "PrizeSavings"

/// Transaction to update draw interval for a pool
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.updatePoolDrawInterval(
            poolID: poolID,
            newInterval: newInterval,
            updatedBy: signer.address
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()))
    }
}

