import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Start Draw transaction - Initiates a lottery draw for a pool (Admin only)
/// This commits to a future block's randomness and snapshots TWAB weights
///
/// Parameters:
/// - poolID: The ID of the pool to start a draw for
transaction(poolID: UInt64) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Borrow the Admin resource with CriticalOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }
    
    execute {
        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
        
        // Check if draw can happen now
        if !poolRef.canDrawNow() {
            panic("Cannot start draw yet - not enough time since last draw")
        }
        
        // Check if draw is already in progress
        if poolRef.isDrawInProgress() {
            panic("Draw already in progress - call completeDraw first")
        }
        
        // Start the draw (commits to randomness)
        self.adminRef.startPoolDraw(poolID: poolID)
        
        log("Draw started for pool ".concat(poolID.toString()))
        log("Wait at least 1 block, then call completeDraw")
    }
}
