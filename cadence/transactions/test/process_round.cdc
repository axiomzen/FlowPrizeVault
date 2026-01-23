import "PrizeLinkedAccounts"

/// Process Round transaction (Test version)
///
/// Idempotent transaction that advances round completion. Call repeatedly until done.
/// Uses default batch limit of 100.
///
/// State Machine:
/// 1. Round ended → startDraw()
/// 2. Batch in progress → processDrawBatch()
/// 3. Batch complete → requestDrawRandomness()
/// 4. Randomness ready → completeDraw()
/// 5. In intermission → Done (call startNextRound separately)
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let poolRef: &PrizeLinkedAccounts.Pool

    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        self.poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
    }

    execute {
        let batchLimit = 100

        // In intermission - nothing to do
        if self.poolRef.isInIntermission() && !self.poolRef.isPendingDrawInProgress() {
            log("In intermission - call startNextRound()")
            return
        }

        // Phase 4: Complete draw
        if self.poolRef.isReadyForDrawCompletion() {
            self.adminRef.completePoolDraw(poolID: poolID)
            log("Draw completed!")
            return
        }

        // Phase 3: Request randomness
        if self.poolRef.isDrawBatchComplete() {
            self.adminRef.requestPoolDrawRandomness(poolID: poolID)
            log("Randomness requested - wait 1 block")
            return
        }

        // Phase 2: Process batch
        if self.poolRef.isPendingDrawInProgress() && !self.poolRef.isDrawBatchComplete() {
            let remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchLimit)
            log("Batch processed, remaining: ".concat(remaining.toString()))
            return
        }

        // Phase 1: Start draw
        if self.poolRef.canDrawNow() && !self.poolRef.isPendingDrawInProgress() {
            self.adminRef.startPoolDraw(poolID: poolID)
            log("Draw started!")
            return
        }

        // Waiting for randomness block
        if self.poolRef.isDrawInProgress() && !self.poolRef.isReadyForDrawCompletion() {
            log("Waiting for next block (randomness)")
            return
        }

        // Round still active
        log("Round active - nothing to do")
    }
}
