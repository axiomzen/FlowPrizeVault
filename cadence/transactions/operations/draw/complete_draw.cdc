import "PrizeLinkedAccounts"

/// Complete Draw — Phase 3 of the draw cycle (requires CriticalOps).
///
/// Reveals the committed randomness, selects winner(s) via weighted binary search,
/// and auto-compounds prizes into winner share balances. Pool enters intermission.
///
/// MUST be called in a DIFFERENT block from start_draw.cdc — this is enforced
/// by Flow's randomness commit-reveal protocol and will panic if called same-block.
///
/// Pre-conditions (checked automatically):
///   - A draw is in progress (start_draw.cdc was called)
///   - All TWAB batches have been processed (process_draw_batch.cdc returned 0)
///
/// After this transaction: call draw/start_next_round.cdc (ConfigOps) to begin the next round.
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminCriticalOps
            ) ?? panic("No CriticalOps access. Sign with deployer or run setup/claim_critical_ops_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("CriticalOps capability is invalid or has been revoked.")
        }
    }

    execute {
        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool ".concat(poolID.toString()).concat(" does not exist"))

        if !poolRef.isDrawInProgress() {
            panic("No draw in progress — call start_draw.cdc first")
        }

        self.adminRef.completePoolDraw(poolID: poolID)

        log("Draw completed for pool ".concat(poolID.toString()).concat(" — prizes distributed, pool entering intermission"))
        log("Next: call start_next_round.cdc to begin the next prize round")
    }
}
