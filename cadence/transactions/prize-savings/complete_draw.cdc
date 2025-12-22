import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Complete Draw transaction - Finalizes a lottery draw for a pool (Admin only)
/// This reveals the random number and selects winner(s)
/// Must be called after startDraw and at least 1 block has passed
///
/// Parameters:
/// - poolID: The ID of the pool to complete the draw for
transaction(poolID: UInt64) {
    
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
        
        // Check if draw is in progress
        if !poolRef.isDrawInProgress() {
            panic("No draw in progress - call startDraw first")
        }
        
        // Complete the draw (selects winners and distributes prizes)
        self.adminRef.completePoolDraw(poolID: poolID)
        
        log("Draw completed for pool ".concat(poolID.toString()))
    }
}
