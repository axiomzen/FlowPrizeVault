import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Emergency mode information structure
access(all) struct EmergencyInfo {
    access(all) let state: UInt8
    access(all) let stateName: String
    access(all) let isNormal: Bool
    access(all) let isPaused: Bool
    access(all) let isEmergencyMode: Bool
    access(all) let isPartialMode: Bool
    access(all) let emergencyDetails: {String: AnyStruct}?
    
    init(
        state: UInt8,
        stateName: String,
        isNormal: Bool,
        isPaused: Bool,
        isEmergencyMode: Bool,
        isPartialMode: Bool,
        emergencyDetails: {String: AnyStruct}?
    ) {
        self.state = state
        self.stateName = stateName
        self.isNormal = isNormal
        self.isPaused = isPaused
        self.isEmergencyMode = isEmergencyMode
        self.isPartialMode = isPartialMode
        self.emergencyDetails = emergencyDetails
    }
}

/// Get emergency mode information for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: EmergencyInfo struct with emergency state details
access(all) fun main(poolID: UInt64): EmergencyInfo {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let state = poolRef.getEmergencyState()
    var stateName = "Unknown"
    
    switch state {
        case PrizeSavings.PoolEmergencyState.Normal:
            stateName = "Normal"
        case PrizeSavings.PoolEmergencyState.Paused:
            stateName = "Paused"
        case PrizeSavings.PoolEmergencyState.EmergencyMode:
            stateName = "EmergencyMode"
        case PrizeSavings.PoolEmergencyState.PartialMode:
            stateName = "PartialMode"
    }
    
    return EmergencyInfo(
        state: state.rawValue,
        stateName: stateName,
        isNormal: state == PrizeSavings.PoolEmergencyState.Normal,
        isPaused: state == PrizeSavings.PoolEmergencyState.Paused,
        isEmergencyMode: poolRef.isEmergencyMode(),
        isPartialMode: poolRef.isPartialMode(),
        emergencyDetails: poolRef.getEmergencyInfo()
    )
}

