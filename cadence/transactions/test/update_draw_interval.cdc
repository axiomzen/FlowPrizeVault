import "PrizeSavings"

/// Transaction to update draw interval for future rounds
/// Note: This only affects rounds created AFTER the next startDraw().
/// The current round's timing is NOT affected.
/// To also change the current round's draw timing, use update_draw_interval_current_round.cdc
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()))
    }
}

