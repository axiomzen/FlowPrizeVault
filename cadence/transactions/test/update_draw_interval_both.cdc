import "PrizeSavings"

/// Transaction to update draw interval for BOTH future rounds AND current round.
/// This provides the combined behavior for tests that need to update everything at once.
transaction(poolID: UInt64, newInterval: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Update future rounds
        admin.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        // Also update current round's draw timing
        admin.updatePoolDrawIntervalForCurrentRound(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()).concat(" (both future and current round)"))
    }
}

