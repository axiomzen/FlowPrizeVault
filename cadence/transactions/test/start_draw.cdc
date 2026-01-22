import "PrizeLinkedAccounts"

/// Start a prize draw for a pool (Admin only)
transaction(poolID: UInt64) {
    
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.startPoolDraw(poolID: poolID)
        log("Draw started for pool ".concat(poolID.toString()))
    }
}
