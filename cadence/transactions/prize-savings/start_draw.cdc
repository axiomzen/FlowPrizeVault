import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Start Draw transaction - Initiates a lottery draw for a pool
/// This commits to a future block's randomness and snapshots TWAB weights
/// Anyone can call this if conditions are met (enough time since last draw)
///
/// Parameters:
/// - poolID: The ID of the pool to start a draw for
transaction(poolID: UInt64) {
    
    prepare(signer: &Account) {
        // No special permissions needed - this is permissionless
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
        
        // Start the draw (commits to randomness)
        poolRef.startDraw()
        
        log("Draw started for pool ".concat(poolID.toString()))
        log("Wait at least 1 block, then call completeDraw")
    }
}

