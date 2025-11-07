import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Process rewards for a pool - collects and distributes to savings and lottery
///
/// Parameters:
/// - poolID: The ID of the pool
transaction(poolID: UInt64) {
    
    let poolRef: auth(PrizeVaultModular.PoolAccess) &PrizeVaultModular.Pool
    
    prepare(signer: auth(Storage) &Account) {
        self.poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
            ?? panic("Pool does not exist")
    }
    
    execute {
        self.poolRef.processRewards()
        log("Rewards processed for pool ".concat(poolID.toString()))
    }
}

