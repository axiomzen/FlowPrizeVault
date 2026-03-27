import "PrizeLinkedAccounts"

/// Start Next Round — Phase 4 of the draw cycle (requires ConfigOps).
///
/// Exits intermission and creates a new prize round. TWAB tracking resumes
/// immediately for existing depositors.
///
/// During intermission (between complete_draw.cdc and this transaction):
///   - Deposits and withdrawals are allowed, but TWAB is not recorded
///   - Draws are blocked
///   - Yield continues accruing
///   - Config changes (draw interval, minimum deposit) can be made
///
/// Signer: deployer account OR ops/automation account with ConfigOps capability
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminConfigOps
            ) ?? panic("No ConfigOps access. Sign with deployer or run setup/claim_config_ops_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("ConfigOps capability is invalid or has been revoked.")
        }
    }

    execute {
        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool ".concat(poolID.toString()).concat(" does not exist"))

        if !poolRef.isInIntermission() {
            panic("Pool is not in intermission — a round is already active")
        }

        self.adminRef.startNextRound(poolID: poolID)

        log("Next round started for pool ".concat(poolID.toString()))
    }
}
