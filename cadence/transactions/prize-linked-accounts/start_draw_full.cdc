import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Smart Draw Transaction - Intelligently advances the draw process (Admin only)
///
/// This transaction checks the pool's current state and performs the appropriate action:
///   - If awaiting draw: starts the draw and processes all batches
///   - If batch processing in progress: continues processing batches
///   - If batch complete: completes the draw and distributes prizes
///   - If in intermission: starts the next round
///
/// Call this transaction repeatedly until the draw cycle is complete.
/// Note: completeDraw must be called in a different block than startDraw (randomness requirement).
///
/// Parameters:
/// - poolID: The ID of the pool to advance the draw for
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin
    let poolRef: &PrizeLinkedAccounts.Pool

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with CriticalOps and ConfigOps entitlements
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")

        // Borrow pool reference for state checks
        self.poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool not found: ".concat(poolID.toString()))
    }

    execute {
        // Batch size optimized for gas limits while processing efficiently
        let batchSize = 2000

        // Check pool state and take appropriate action

        // STATE 1: Pool is in intermission (draw completed, waiting for next round)
        if self.poolRef.isInIntermission() {
            self.adminRef.startNextRound(poolID: poolID)
            log("Started next round for pool ".concat(poolID.toString()))
            return
        }

        // STATE 2: Round is active but hasn't ended yet
        if !self.poolRef.canDrawNow() && !self.poolRef.isDrawInProgress() {
            log("Round has not ended yet - no action taken")
            return
        }

        // STATE 3: Ready to start a new draw
        if self.poolRef.isAwaitingDraw() {
            // Start the draw (includes yield materialization and randomness request)
            self.adminRef.startPoolDraw(poolID: poolID)
            log("Phase 1: Draw started for pool ".concat(poolID.toString()))

            // Process all batches
            var batchCount = 0
            var remaining = 1
            while remaining > 0 {
                remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchSize)
                batchCount = batchCount + 1
            }
            log("Phase 2: Processed all receivers in ".concat(batchCount.toString()).concat(" batches"))
            log("Ready for Phase 3: call this transaction again in the next block to complete")
            return
        }

        // STATE 4: Draw in progress, batches still need processing
        if self.poolRef.isDrawBatchInProgress() {
            var batchCount = 0
            var remaining = 1
            while remaining > 0 {
                remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchSize)
                batchCount = batchCount + 1
            }
            log("Phase 2: Processed remaining receivers in ".concat(batchCount.toString()).concat(" batches"))

            if self.poolRef.isReadyForDrawCompletion() {
                log("Ready for Phase 3: call this transaction again in the next block to complete")
            }
            return
        }

        // STATE 5: Batches complete, ready to finalize draw
        if self.poolRef.isReadyForDrawCompletion() {
            self.adminRef.completePoolDraw(poolID: poolID)
            log("Phase 3: Draw completed - prizes distributed!")

            // Auto-start next round if now in intermission
            if self.poolRef.isInIntermission() {
                self.adminRef.startNextRound(poolID: poolID)
                log("Started next round automatically")
            }
            return
        }

        log("Pool is in an unexpected state - no action taken")
    }
}

