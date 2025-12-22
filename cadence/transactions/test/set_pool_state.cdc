import "PrizeSavings"

/// Transaction to set pool state (0=Normal, 1=Paused, 2=EmergencyMode, 3=PartialMode)
transaction(poolID: UInt64, stateRaw: UInt8, reason: String) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let state = PrizeSavings.PoolEmergencyState(rawValue: stateRaw)
            ?? panic("Invalid state value")
        
        admin.setPoolState(poolID: poolID, state: state, reason: reason)
        
        log("Pool state set to ".concat(stateRaw.toString()).concat(" for pool ").concat(poolID.toString()))
    }
}

