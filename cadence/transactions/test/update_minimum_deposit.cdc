import "PrizeLinkedAccounts"

/// Transaction to update minimum deposit for a pool
transaction(poolID: UInt64, newMinimum: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.updatePoolMinimumDeposit(
            poolID: poolID,
            newMinimum: newMinimum
        )
        
        log("Updated minimum deposit for pool ".concat(poolID.toString()))
    }
}

