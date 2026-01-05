import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Update Draw Interval for Future Rounds (Admin only)
///
/// This transaction changes the draw interval for FUTURE rounds only.
/// Rounds created after the next startDraw() will use the new interval.
///
/// IMPORTANT:
/// - Does NOT affect the current round's duration or lottery eligibility
/// - The current round's duration is immutable once created
///
/// Parameters:
/// - poolID: The ID of the pool to update
/// - newInterval: The new draw interval in seconds (e.g., 86400.0 for daily)
transaction(poolID: UInt64, newInterval: UFix64) {
    
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with ConfigOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )
        
        log("Updated draw interval for pool ".concat(poolID.toString()).concat(" to ").concat(newInterval.toString()).concat(" seconds (future rounds only)"))
    }
}

