import "PrizeLinkedAccounts"

/// Transaction to update draw interval for a pool.
/// Note: This only affects rounds created AFTER the next startDraw().
/// The current round's duration is immutable once created.
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()))
    }
}

