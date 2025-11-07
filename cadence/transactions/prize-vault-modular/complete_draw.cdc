import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Complete a lottery draw - fulfills randomness and awards prize
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
        self.poolRef.completeDraw()
        log("Draw completed for pool ".concat(poolID.toString()))
    }
}

