import "PrizeSavings"

/// Complete a lottery draw for a pool
transaction(poolID: UInt64) {
    
    prepare(signer: &Account) {
        // No storage needed - just calling public function
    }
    
    execute {
        let poolRef = PrizeSavings.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
        
        poolRef.completeDraw()
        log("Draw completed for pool ".concat(poolID.toString()))
    }
}

