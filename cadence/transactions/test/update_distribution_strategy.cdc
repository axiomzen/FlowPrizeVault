import "PrizeLinkedAccounts"

/// Transaction to update distribution strategy for a pool
transaction(poolID: UInt64, rewardsPercent: UFix64, prizePercent: UFix64, treasuryPercent: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let newStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            treasury: treasuryPercent
        )
        
        admin.updatePoolDistributionStrategy(
            poolID: poolID,
            newStrategy: newStrategy
        )
        
        log("Updated distribution strategy for pool ".concat(poolID.toString()))
    }
}

