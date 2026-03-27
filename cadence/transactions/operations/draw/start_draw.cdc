import "PrizeLinkedAccounts"

/// Start Draw — Phase 1 of the draw cycle (requires CriticalOps).
///
/// Commits to a future block's randomness, materializes protocol fees, syncs yield,
/// snapshots the receiver list, and creates batch selection data.
///
/// Pre-conditions (checked automatically):
///   - Current round has ended (targetEndTime has passed)
///   - No draw is already in progress
///   - allocatedPrizeYield > 0 (fund the prize pool if zero)
///
/// After this transaction: call process_draw_batch.cdc (permissionless) until complete,
/// then call complete_draw.cdc in the NEXT block (randomness commit-reveal requirement).
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        // Deployer: Admin resource is stored directly at AdminStoragePath
        // Operator: Admin capability stored after claim_critical_ops_capability.cdc
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

        if !poolRef.canDrawNow() {
            panic("Round has not ended yet — check get_draw_status.cdc for secondsUntilNextDraw")
        }

        if poolRef.isDrawInProgress() {
            panic("Draw already in progress — call complete_draw.cdc instead")
        }

        self.adminRef.startPoolDraw(poolID: poolID)

        log("Draw started for pool ".concat(poolID.toString()))
        log("Next: run process_draw_batch.cdc until complete, then complete_draw.cdc in the next block")
    }
}
