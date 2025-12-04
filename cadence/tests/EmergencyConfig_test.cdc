import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Default Emergency Config
// ============================================================================

access(all) fun testDefaultEmergencyConfigValues() {
    // Create pool with nil emergency config (uses defaults)
    createTestPool()
    
    let poolID = UInt64(getPoolCount() - 1)
    let config = getEmergencyConfigDetails(poolID)
    
    // Default values from createDefaultEmergencyConfig():
    // maxEmergencyDuration: 86400.0
    // autoRecoveryEnabled: true
    // minYieldSourceHealth: 0.5
    // maxWithdrawFailures: 3
    // partialModeDepositLimit: 100.0
    // minBalanceThreshold: 0.95
    // minRecoveryHealth: 0.5
    
    Test.assertEqual(true, config["autoRecoveryEnabled"]! as! Bool)
    Test.assertEqual(0.5, config["minYieldSourceHealth"]! as! UFix64)
    Test.assertEqual(3, config["maxWithdrawFailures"]! as! Int)
    Test.assertEqual(0.95, config["minBalanceThreshold"]! as! UFix64)
}

// ============================================================================
// TESTS - minYieldSourceHealth Boundaries
// ============================================================================

access(all) fun testEmergencyConfigMinYieldHealthBoundary0() {
    // minYieldSourceHealth = 0.0 should be valid
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.0,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(0.0, config["minYieldSourceHealth"]! as! UFix64)
}

access(all) fun testEmergencyConfigMinYieldHealthBoundary1() {
    // minYieldSourceHealth = 1.0 should be valid
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 1.0,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(1.0, config["minYieldSourceHealth"]! as! UFix64)
}

access(all) fun testEmergencyConfigMinYieldHealthAboveOneReverts() {
    // minYieldSourceHealth > 1.0 should fail
    let success = createPoolWithEmergencyConfigExpectFailure(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 1.1,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - maxWithdrawFailures Boundaries
// ============================================================================

access(all) fun testEmergencyConfigMaxWithdrawFailuresMin() {
    // maxWithdrawFailures = 1 should be valid (minimum)
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 1,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(1, config["maxWithdrawFailures"]! as! Int)
}

access(all) fun testEmergencyConfigMaxWithdrawFailuresZeroReverts() {
    // maxWithdrawFailures = 0 should fail
    let success = createPoolWithEmergencyConfigExpectFailure(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 0,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - minBalanceThreshold Boundaries
// ============================================================================

access(all) fun testEmergencyConfigBalanceThreshold0_8() {
    // minBalanceThreshold = 0.8 should be valid (minimum)
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.8,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(0.8, config["minBalanceThreshold"]! as! UFix64)
}

access(all) fun testEmergencyConfigBalanceThreshold1_0() {
    // minBalanceThreshold = 1.0 should be valid (maximum)
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 1.0,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(1.0, config["minBalanceThreshold"]! as! UFix64)
}

access(all) fun testEmergencyConfigBalanceThresholdBelow0_8Reverts() {
    // minBalanceThreshold < 0.8 should fail
    let success = createPoolWithEmergencyConfigExpectFailure(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.7,
        minRecoveryHealth: 0.5
    )
    Test.assertEqual(false, success)
}

access(all) fun testEmergencyConfigBalanceThresholdAbove1_0Reverts() {
    // minBalanceThreshold > 1.0 should fail
    let success = createPoolWithEmergencyConfigExpectFailure(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 1.1,
        minRecoveryHealth: 0.5
    )
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - Auto Recovery Settings
// ============================================================================

access(all) fun testEmergencyConfigAutoRecoveryEnabled() {
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(true, config["autoRecoveryEnabled"]! as! Bool)
}

access(all) fun testEmergencyConfigAutoRecoveryDisabled() {
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 86400.0,
        autoRecoveryEnabled: false,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(false, config["autoRecoveryEnabled"]! as! Bool)
}

// ============================================================================
// TESTS - Max Duration Settings
// ============================================================================

access(all) fun testEmergencyConfigMaxDurationSet() {
    let poolID = createPoolWithEmergencyConfig(
        maxEmergencyDuration: 172800.0,  // 2 days
        autoRecoveryEnabled: true,
        minYieldSourceHealth: 0.5,
        maxWithdrawFailures: 3,
        partialModeDepositLimit: 100.0,
        minBalanceThreshold: 0.95,
        minRecoveryHealth: 0.5
    )
    
    let config = getEmergencyConfigDetails(poolID)
    Test.assertEqual(172800.0, config["maxEmergencyDuration"]! as! UFix64)
}

// ============================================================================
// TESTS - Pool Emergency State Transitions
// ============================================================================

access(all) fun testPoolEmergencyStateTransitions() {
    let poolID = createTestPoolWithShortInterval()
    
    // Should start in Normal state (0)
    var state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(0), state)
    
    // Enable emergency mode
    enablePoolEmergencyMode(poolID, reason: "Test emergency")
    state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(2), state)  // EmergencyMode = 2
    
    // Disable emergency mode
    disablePoolEmergencyMode(poolID)
    state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(0), state)  // Normal = 0
}

access(all) fun testPoolPausedStateBlocksOperations() {
    let poolID = createTestPoolWithShortInterval()
    
    // Set to Paused state (1)
    setPoolState(poolID, state: 1, reason: "Maintenance")
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(1), state)  // Paused = 1
    
    // Reset to Normal for cleanup
    setPoolState(poolID, state: 0, reason: "")
}

access(all) fun testPartialModeState() {
    let poolID = createTestPoolWithShortInterval()
    
    // Set to PartialMode state (3)
    setPoolState(poolID, state: 3, reason: "Limited operations")
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(3), state)  // PartialMode = 3
    
    // Reset to Normal for cleanup
    setPoolState(poolID, state: 0, reason: "")
}

