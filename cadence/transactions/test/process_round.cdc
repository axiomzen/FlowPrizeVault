import "PrizeLinkedAccounts"

/// Process Round transaction (Test version)
///
/// Idempotent transaction that advances round completion. Call repeatedly until done.
/// Uses default batch limit of 100.
///
/// State Machine (3-phase draw):
/// 1. Round ended → startDraw() (includes randomness request)
/// 2. Batch in progress → processDrawBatch()
/// 3. Batch complete + 1 block passed → completeDraw()
/// 4. In intermission → Done (call startNextRound separately)
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
        // (isInIntermission already implies no draw in progress)
        if self.poolRef.isInIntermission() {
            log("In intermission - call startNextRound()")
            return
        }

        // Phase 3: Complete draw (batch complete + randomness ready)
        if self.poolRef.isReadyForDrawCompletion() {
            self.adminRef.completePoolDraw(poolID: poolID)
            log("Draw completed!")
            return
        }

        // Phase 2: Process batch (if batch not complete)
        if self.poolRef.isDrawInProgress() && !self.poolRef.isDrawBatchComplete() {
            let remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchLimit)
            log("Batch processed, remaining: ".concat(remaining.toString()))
            return
        }

        // Batch complete but waiting for randomness block
        if self.poolRef.isDrawBatchComplete() && !self.poolRef.isReadyForDrawCompletion() {
            log("Batch complete - waiting for next block (randomness)")
            return
        }

        // Phase 1: Start draw (includes randomness request)
        if self.poolRef.canDrawNow() && !self.poolRef.isDrawInProgress() {
            self.adminRef.startPoolDraw(poolID: poolID)
            log("Draw started! (randomness requested)")
            return
        }

        // Round still active
        log("Round active - nothing to do")
    }
}
