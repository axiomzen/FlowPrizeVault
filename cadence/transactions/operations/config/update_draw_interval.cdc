import "PrizeLinkedAccounts"

/// Update Draw Interval — applies to future rounds only (requires ConfigOps).
///
/// Changes the duration between prize draws. The current round is unaffected;
/// the new interval takes effect when startNextRound() creates the next round.
///
/// Common values:
///   86400.0   — daily
///   604800.0  — weekly
///   2592000.0 — monthly (30 days)
///
/// Signer: deployer account OR ops/automation account with ConfigOps capability
transaction(poolID: UInt64, newInterval: UFix64) {

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
        self.adminRef.updatePoolDrawIntervalForFutureRounds(
            poolID: poolID,
            newInterval: newInterval
        )

        log("Draw interval updated for pool ".concat(poolID.toString())
            .concat(" to ").concat(newInterval.toString()).concat("s (takes effect next round)"))
    }
}
