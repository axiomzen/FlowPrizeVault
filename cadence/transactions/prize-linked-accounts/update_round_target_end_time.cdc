import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Update Current Round Target End Time (Admin only)
///
/// This transaction updates the target end time for the current active round.
/// Use this to extend or shorten the current round's timing.
///
/// IMPORTANT:
/// - Can only be called before startDraw() is called on this round
/// - Does NOT unfairly change existing users' TWAB (math adapts automatically)
/// - newTargetEndTime must be after the round's start time
///
/// Parameters:
/// - poolID: The ID of the pool to update
/// - newTargetEndTime: The new target end time (Unix timestamp in seconds)
///
/// Example: To extend round by 1 day, add 86400 to current target
transaction(poolID: UInt64, newTargetEndTime: UFix64) {

    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with ConfigOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }

    execute {
        self.adminRef.updateCurrentRoundTargetEndTime(
            poolID: poolID,
            newTargetEndTime: newTargetEndTime
        )

        log("Updated round target end time for pool ".concat(poolID.toString()).concat(" to ").concat(newTargetEndTime.toString()))
    }
}
