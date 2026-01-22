import "PrizeLinkedAccounts"

/// Get the emergency state of a pool (0=Normal, 1=Paused, 2=EmergencyMode, 3=PartialMode)
access(all) fun main(poolID: UInt64): UInt8 {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")
    
    return poolRef.getEmergencyState().rawValue
}

