import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Process Round transaction - Idempotent transaction for advancing round completion
///
/// This transaction can be called repeatedly until the round is fully processed.
/// It automatically detects the current state and performs the next required action:
///
/// State Machine:
/// 1. Round ended (canDrawNow) → startDraw()
/// 2. Batch in progress → processDrawBatch()
/// 3. Batch complete → requestDrawRandomness()
/// 4. Randomness ready → completeDraw()
/// 5. In intermission → Nothing to do (call startNextRound separately)
///
/// Parameters:
/// - poolID: The ID of the pool to process
/// - batchLimit: Maximum receivers to process per batch (default 100)
///
/// Returns via logs:
/// - The action taken and current state
/// - Whether more calls are needed
transaction(poolID: UInt64, batchLimit: Int) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let poolRef: &PrizeLinkedAccounts.Pool

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with CriticalOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")

        self.poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
    }

    execute {
        // Check if pool is in intermission (round complete, waiting for startNextRound)
        if self.poolRef.isInIntermission() && !self.poolRef.isPendingDrawInProgress() {
            log("STATUS: In intermission - round complete")
            log("ACTION: None - call startNextRound() to begin next round")
            log("DONE: true")
            return
        }

        // Phase 4: Complete draw if randomness is ready
        if self.poolRef.isReadyForDrawCompletion() {
            log("STATUS: Randomness ready")
            log("ACTION: Completing draw and selecting winners...")
            self.adminRef.completePoolDraw(poolID: poolID)
            log("RESULT: Draw completed! Winners selected and prizes distributed.")
            log("DONE: true (now in intermission)")
            return
        }

        // Phase 3: Request randomness if batch is complete
        if self.poolRef.isDrawBatchComplete() {
            log("STATUS: Batch processing complete")
            log("ACTION: Requesting randomness...")
            self.adminRef.requestPoolDrawRandomness(poolID: poolID)
            log("RESULT: Randomness requested. Wait 1 block, then call again.")
            log("DONE: false (need to wait 1 block)")
            return
        }

        // Phase 2: Process batch if draw started but batch not complete
        if self.poolRef.isPendingDrawInProgress() && !self.poolRef.isDrawBatchComplete() {
            log("STATUS: Batch processing in progress")
            log("ACTION: Processing next batch (limit: ".concat(batchLimit.toString()).concat(")..."))

            let newRemaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchLimit)

            if newRemaining == 0 {
                log("RESULT: Batch complete!")
                log("DONE: false (call again to request randomness)")
            } else {
                log("RESULT: Processed batch. ".concat(newRemaining.toString()).concat(" receivers remaining."))
                log("DONE: false (call again to continue processing)")
            }
            return
        }

        // Phase 1: Start draw if round has ended and no draw in progress
        if self.poolRef.canDrawNow() && !self.poolRef.isPendingDrawInProgress() {
            log("STATUS: Round ended, ready to start draw")
            log("ACTION: Starting draw...")
            self.adminRef.startPoolDraw(poolID: poolID)
            log("RESULT: Draw started! TWAB snapshot taken.") 
            log("DONE: false (call again to process batch)")
            return
        }

        // Nothing to do - round still active or waiting for block
        if self.poolRef.isDrawInProgress() && !self.poolRef.isReadyForDrawCompletion() {
            log("STATUS: Waiting for randomness (need to wait 1 block)")
            log("ACTION: None - try again after next block")
            log("DONE: false (waiting for block)")
            return
        }

        // Round still active
        let timeUntilDraw = self.poolRef.getTimeUntilNextDraw()
        log("STATUS: Round still active")
        log("TIME_UNTIL_DRAW: ".concat(timeUntilDraw.toString()).concat(" seconds"))
        log("ACTION: None - round has not ended yet")
        log("DONE: true (nothing to process)")
    }
}
