import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Start Draw Full transaction - Handles phases 1-3 of the draw process (Admin only)
/// 
/// This transaction performs:
///   1. startDraw() - Initiates the draw, creates pendingDrawRound
///   2. processDrawBatch() - Processes all receivers in batches (loops until complete)
///   3. requestDrawRandomness() - Requests on-chain randomness for winner selection
///
/// After this transaction, wait at least 1 block, then call complete_draw.cdc to finalize.
///
/// Parameters:
/// - poolID: The ID of the pool to start the draw for
/// - batchSize: Number of receivers to process per batch (recommended: 100-500)
transaction(poolID: UInt64, batchSize: Int) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with CriticalOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        // Phase 1: Start the draw
        self.adminRef.startPoolDraw(poolID: poolID)
        log("Phase 1: Draw started for pool ".concat(poolID.toString()))
        
        // Phase 2: Process all batches
        var totalProcessed = 0
        var batchCount = 0
        var remaining = 1 // Start with non-zero to enter loop
        
        while remaining > 0 {
            remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchSize)
            batchCount = batchCount + 1
            totalProcessed = totalProcessed + batchSize
        }
        log("Phase 2: Processed all receivers in ".concat(batchCount.toString()).concat(" batches"))
        
        // Phase 3: Request randomness
        self.adminRef.requestPoolDrawRandomness(poolID: poolID)
        log("Phase 3: Randomness requested - call complete_draw.cdc after next block")
    }
}

