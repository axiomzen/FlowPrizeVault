import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Update Draw Timing for Current Round (Admin only)
///
/// This transaction changes when the current round's draw can start.
/// It updates the configuredDuration which controls when hasEnded() returns true.
///
/// IMPORTANT:
/// - Does NOT affect lottery eligibility (eligibilityDuration is immutable)
/// - Does NOT retroactively change existing users' lottery odds
/// - Does NOT affect future rounds (use update_draw_interval.cdc for that)
///
/// WARNING: If you extend beyond the original eligibilityDuration, new deposits
/// after eligibilityDuration will get ZERO lottery weight for this round, even
/// though the round appears "active". Those deposits count in the NEXT round.
///
/// Use cases:
/// - Delay a draw if you need more time (operational)
/// - Extend the current round for operational reasons
/// - Shorten the round to trigger draw earlier
///
/// Parameters:
/// - poolID: The ID of the pool to update
/// - newDuration: The new duration for the current round in seconds
transaction(poolID: UInt64, newDuration: UFix64) {
    
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with ConfigOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        self.adminRef.updatePoolDrawIntervalForCurrentRound(
            poolID: poolID,
            newInterval: newDuration
        )
        
        log("Updated current round duration for pool ".concat(poolID.toString()).concat(" to ").concat(newDuration.toString()).concat(" seconds"))
    }
}

