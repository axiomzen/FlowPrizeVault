import "PrizeLinkedAccounts"

/// Smart Draw — Intelligently advances the full draw cycle (requires CriticalOps + ConfigOps).
///
/// Inspects the pool state and performs the appropriate action automatically:
///   - ROUND_ACTIVE (not ended): logs and exits
///   - AWAITING_DRAW: starts draw + processes all TWAB batches in one call
///   - DRAW_PROCESSING: processes remaining batches
///   - After batches complete: completes draw + distributes prizes + starts next round
///   - INTERMISSION: starts next round
///
/// Two-call pattern (required by Flow's randomness commit-reveal):
///   Call 1 (block N)   → starts draw, processes all batches
///   Call 2 (block N+1) → completes draw, starts next round
///
/// Signer: deployer account OR ops account with full Admin capability
///   (claim via setup/claim_full_admin_capability.cdc — requires both CriticalOps + ConfigOps)
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin
    let poolRef: &PrizeLinkedAccounts.Pool

    prepare(signer: auth(Storage) &Account) {
        // Deployer: Admin resource is stored directly at AdminStoragePath
        // Operator: full Admin capability stored after claim_full_admin_capability.cdc
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminFull
            ) ?? panic("No full Admin access. Sign with deployer or run setup/claim_full_admin_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("Full Admin capability is invalid or has been revoked.")
        }

        self.poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool ".concat(poolID.toString()).concat(" not found"))
    }

    execute {
        let batchSize = 2000

        // STATE: Intermission — start the next round
        if self.poolRef.isInIntermission() {
            self.adminRef.startNextRound(poolID: poolID)
            log("Started next round for pool ".concat(poolID.toString()))
            return
        }

        // STATE: Round active, not yet ended
        if !self.poolRef.canDrawNow() && !self.poolRef.isDrawInProgress() {
            log("Round has not ended yet — no action taken")
            return
        }

        // STATE: Awaiting draw — start it and process all batches
        if self.poolRef.isAwaitingDraw() {
            self.adminRef.startPoolDraw(poolID: poolID)
            log("Phase 1: Draw started for pool ".concat(poolID.toString()))

            var remaining = 1
            var batchCount = 0
            while remaining > 0 {
                remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchSize)
                batchCount = batchCount + 1
            }
            log("Phase 2: Processed all receivers in ".concat(batchCount.toString()).concat(" batch(es)"))
            log("Phase 3 ready: call this transaction again in the next block to complete the draw")
            return
        }

        // STATE: Batch processing in progress
        if self.poolRef.isDrawBatchInProgress() {
            var remaining = 1
            var batchCount = 0
            while remaining > 0 {
                remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchSize)
                batchCount = batchCount + 1
            }
            log("Phase 2: Processed remaining receivers in ".concat(batchCount.toString()).concat(" batch(es)"))
            if self.poolRef.isReadyForDrawCompletion() {
                log("Phase 3 ready: call this transaction again in the next block to complete the draw")
            }
            return
        }

        // STATE: Batches complete — finalize draw and start next round
        if self.poolRef.isReadyForDrawCompletion() {
            self.adminRef.completePoolDraw(poolID: poolID)
            log("Phase 3: Draw completed — prizes distributed!")

            if self.poolRef.isInIntermission() {
                self.adminRef.startNextRound(poolID: poolID)
                log("Phase 4: Next round started automatically")
            }
            return
        }

        log("Pool is in an unexpected state — check get_draw_status.cdc")
    }
}
