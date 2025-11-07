import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Start a lottery draw - commits randomness request
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
        self.poolRef.startDraw()
        log("Draw started for pool ".concat(poolID.toString()))
    }
}

