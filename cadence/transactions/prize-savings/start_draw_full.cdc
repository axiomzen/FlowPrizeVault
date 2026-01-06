import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Start Draw Full transaction - Initiates and prepares a lottery draw in one transaction (Admin only)
/// This performs phases 1-3 of the draw process:
/// 1. Start draw (snapshot TWAB)
/// 2. Process all batches (capture weights)
/// 3. Request randomness
///
/// After this, call complete_draw.cdc (phase 4) to select winners and distribute prizes.
///
/// Parameters:
/// - poolID: The ID of the pool to start a draw for
/// - batchLimit: Maximum receivers to process per batch iteration
transaction(poolID: UInt64, batchLimit: Int) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with CriticalOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
        
        // Check if draw can happen now
        if !poolRef.canDrawNow() {
            panic("Cannot start draw yet - not enough time since last draw")
        }
        
        // Check if draw is already in progress
        if poolRef.isDrawInProgress() {
            panic("Draw already in progress - call completeDraw first")
        }
        
        // Phase 1: Start the draw (commits to randomness, snapshots TWAB)
        self.adminRef.startPoolDraw(poolID: poolID)
        log("Phase 1: Draw started for pool ".concat(poolID.toString()))
        
        // Phase 2: Process all batches until complete
        var batchCount = 0
        var remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchLimit)
        batchCount = batchCount + 1
        
        while remaining > 0 {
            remaining = self.adminRef.processPoolDrawBatch(poolID: poolID, limit: batchLimit)
            batchCount = batchCount + 1
        }
        log("Phase 2: Processed ".concat(batchCount.toString()).concat(" batches"))
        
        // Phase 3: Request randomness
        self.adminRef.requestPoolDrawRandomness(poolID: poolID)
        log("Phase 3: Randomness requested")
        
        log("Draw ready for completion. Wait at least 1 block, then call complete_draw.cdc")
    }
}

