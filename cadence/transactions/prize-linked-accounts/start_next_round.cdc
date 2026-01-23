import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Start Next Round transaction - Exits intermission and begins a new prize round (Admin only)
///
/// After completeDraw() finishes, the pool enters intermission (no active round).
/// Call this transaction to start a new prize round.
///
/// During intermission:
/// - Deposits/withdrawals are allowed (no TWAB recorded)
/// - Draws are blocked
/// - Yield continues accruing
/// - Admin can configure settings for the next round
///
/// Parameters:
/// - poolID: The ID of the pool to start the next round for
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with ConfigOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }

    execute {
        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")

        // Check if pool is in intermission
        if !poolRef.isInIntermission() {
            panic("Pool is not in intermission - round already active")
        }

        // Start the next round (exits intermission)
        self.adminRef.startNextRound(poolID: poolID)

        log("Next round started for pool ".concat(poolID.toString()))
    }
}
