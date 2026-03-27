import "PrizeLinkedAccounts"

/// Cleanup Stale Entries — removes ghost receivers (requires ConfigOps).
///
/// Ghost receivers are entries for users who have withdrawn to zero but whose
/// UUID still appears in the receiver list. They add overhead to batch processing.
/// Run this periodically after draws with high user churn.
///
/// Cannot be called while a draw batch is in progress.
///
/// Cursor-based iteration — for large pools, call multiple times:
///   1. First call:  startIndex = 0
///   2. Check log output for "More entries to process" and the next startIndex
///   3. Call again with that startIndex until all entries are processed
///
/// Parameters:
///   poolID     — pool to clean up
///   startIndex — 0 for first call; use nextIndex from previous result to continue
///   limit      — max receivers to inspect per call (100 is safe for most pools)
///
/// Signer: deployer account OR ops/automation account with ConfigOps capability
transaction(poolID: UInt64, startIndex: Int, limit: Int) {

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
        let result = self.adminRef.cleanupPoolStaleEntries(
            poolID: poolID,
            startIndex: startIndex,
            limit: limit
        )

        let nextIndex = result["nextIndex"] ?? 0
        let totalReceivers = result["totalReceivers"] ?? 0

        log("Cleanup for pool ".concat(poolID.toString()).concat(":")
            .concat("\n  Ghost receivers removed: ").concat((result["ghostReceivers"] ?? 0).toString())
            .concat("\n  User shares cleaned: ").concat((result["userShares"] ?? 0).toString())
            .concat("\n  Progress: ").concat(nextIndex.toString()).concat(" / ").concat(totalReceivers.toString()))

        if nextIndex < totalReceivers {
            log("More entries to process — call again with startIndex = ".concat(nextIndex.toString()))
        } else {
            log("All entries processed.")
        }
    }
}
