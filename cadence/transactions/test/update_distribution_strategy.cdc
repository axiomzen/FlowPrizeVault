import "PrizeSavings"

/// Transaction to update distribution strategy for a pool
transaction(poolID: UInt64, savingsPercent: UFix64, lotteryPercent: UFix64, treasuryPercent: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let newStrategy = PrizeSavings.FixedPercentageStrategy(
            savings: savingsPercent,
            lottery: lotteryPercent,
            treasury: treasuryPercent
        )
        
        admin.updatePoolDistributionStrategy(
            poolID: poolID,
            newStrategy: newStrategy,
            updatedBy: signer.address
        )
        
        log("Updated distribution strategy for pool ".concat(poolID.toString()))
    }
}

