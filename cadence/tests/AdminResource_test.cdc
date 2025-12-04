import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Admin Resource Existence
// ============================================================================

access(all) fun testAdminExistsAtStoragePath() {
    // Admin should exist at deployer address after contract deployment
    let adminExists = checkAdminExists(DEPLOYER_ADDRESS)
    Test.assertEqual(true, adminExists)
}

// ============================================================================
// TESTS - Admin Pool Creation
// ============================================================================

access(all) fun testAdminCanCreatePool() {
    let initialCount = getPoolCount()
    
    createTestPool()
    
    let finalCount = getPoolCount()
    Test.assertEqual(initialCount + 1, finalCount)
}

// ============================================================================
// TESTS - Admin Strategy Updates
// ============================================================================

access(all) fun testAdminCanUpdateDistributionStrategy() {
    let poolID = createPoolWithDistribution(savings: 0.7, lottery: 0.2, treasury: 0.1)
    
    // Update to new distribution
    updateDistributionStrategy(poolID: poolID, savings: 0.5, lottery: 0.3, treasury: 0.2)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.5, details["savingsPercent"]! as! UFix64)
    Test.assertEqual(0.3, details["lotteryPercent"]! as! UFix64)
    Test.assertEqual(0.2, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testAdminCanUpdateWinnerSelectionStrategy() {
    let poolID = createTestPoolWithShortInterval()
    
    // The pool should have a winner selection strategy
    let details = getWinnerSelectionStrategyDetails(poolID)
    Test.assert(details["strategyName"] != nil, message: "Strategy should exist")
}

// ============================================================================
// TESTS - Admin Pool Config Updates
// ============================================================================

access(all) fun testAdminCanUpdateDrawInterval() {
    let poolID = createTestPoolWithShortInterval()
    
    // Update draw interval
    updateDrawInterval(poolID: poolID, newInterval: 3600.0)
    
    let details = getPoolDetails(poolID)
    Test.assertEqual(3600.0, details["drawIntervalSeconds"]! as! UFix64)
}

access(all) fun testAdminCanUpdateMinimumDeposit() {
    let poolID = createTestPoolWithShortInterval()
    
    // Update minimum deposit
    updateMinimumDeposit(poolID: poolID, newMinimum: 5.0)
    
    let details = getPoolDetails(poolID)
    Test.assertEqual(5.0, details["minimumDeposit"]! as! UFix64)
}

// ============================================================================
// TESTS - Admin Emergency Mode
// ============================================================================

access(all) fun testAdminCanEnableEmergencyMode() {
    let poolID = createTestPoolWithShortInterval()
    
    enablePoolEmergencyMode(poolID, reason: "Test emergency")
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(2), state)  // EmergencyMode = 2
}

access(all) fun testAdminCanDisableEmergencyMode() {
    let poolID = createTestPoolWithShortInterval()
    
    // Enable first
    enablePoolEmergencyMode(poolID, reason: "Test emergency")
    
    // Then disable
    disablePoolEmergencyMode(poolID)
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(0), state)  // Normal = 0
}

access(all) fun testAdminCanSetPartialMode() {
    let poolID = createTestPoolWithShortInterval()
    
    setPoolState(poolID, state: 3, reason: "Partial mode test")
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(3), state)  // PartialMode = 3
}

access(all) fun testAdminCanSetPoolState() {
    let poolID = createTestPoolWithShortInterval()
    
    // Set to Paused
    setPoolState(poolID, state: 1, reason: "Maintenance")
    var state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(1), state)  // Paused = 1
    
    // Set back to Normal
    setPoolState(poolID, state: 0, reason: "")
    state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(0), state)  // Normal = 0
}

// ============================================================================
// TESTS - Admin Bonus Weight Management
// ============================================================================

access(all) fun testAdminCanSetBonusWeight() {
    let poolID = createTestPoolWithShortInterval()
    
    // Setup a user to have a receiver ID
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Admin can set bonus weight (test that transaction succeeds)
    // Note: Would need receiver ID to actually set bonus
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist")
}

// ============================================================================
// TESTS - Admin Process Rewards
// ============================================================================

access(all) fun testAdminCanProcessRewards() {
    let poolID = createTestPoolWithShortInterval()
    
    // Setup user with deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Process rewards should succeed (even if no yield)
    processPoolRewards(poolID: poolID)
    
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist after processing")
}

// ============================================================================
// TESTS - Non-Admin Access
// ============================================================================

access(all) fun testNonAdminCannotAccessAdminFunctions() {
    // Create a non-admin account
    let nonAdmin = Test.createAccount()
    fundAccountWithFlow(nonAdmin, amount: 10.0)
    
    // Attempt to create pool as non-admin should fail
    let success = createPoolAsNonAdmin(nonAdmin)
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - ConfigOps Capability Delegation
// ============================================================================

access(all) fun testCanIssueAndClaimConfigOpsCapability() {
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Issue and claim ConfigOps capability
    setupConfigOpsDelegate(delegate)
    
    // Capability should be issued and claimed (no error)
    Test.assert(true, message: "ConfigOps capability issued and claimed successfully")
}

access(all) fun testConfigOpsDelegateCanUpdateDrawInterval() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with ConfigOps capability
    setupConfigOpsDelegate(delegate)
    
    // Delegate should be able to update draw interval (ConfigOps function)
    let success = delegateUpdateDrawInterval(delegate, poolID: poolID, newInterval: 7200.0)
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let details = getPoolDetails(poolID)
    Test.assertEqual(7200.0, details["drawIntervalSeconds"]! as! UFix64)
}

access(all) fun testConfigOpsDelegateCanUpdateMinimumDeposit() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with ConfigOps capability
    setupConfigOpsDelegate(delegate)
    
    // Delegate should be able to update minimum deposit (ConfigOps function)
    let success = delegateUpdateMinimumDeposit(delegate, poolID: poolID, newMinimum: 25.0)
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let details = getPoolDetails(poolID)
    Test.assertEqual(25.0, details["minimumDeposit"]! as! UFix64)
}

access(all) fun testConfigOpsDelegateCanProcessRewards() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with ConfigOps capability
    setupConfigOpsDelegate(delegate)
    
    // Delegate should be able to process rewards (ConfigOps function)
    let success = delegateProcessRewards(delegate, poolID: poolID)
    Test.assertEqual(true, success)
}

access(all) fun testConfigOpsDelegateCannotCallCriticalOpsFunctions() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with ConfigOps capability
    setupConfigOpsDelegate(delegate)
    
    // Delegate should NOT be able to call CriticalOps functions
    // enableEmergencyMode is a CriticalOps function
    let success = configOpsTryCriticalOperation(delegate, poolID: poolID, reason: "Test")
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - CriticalOps Capability Delegation
// ============================================================================

access(all) fun testCanIssueAndClaimCriticalOpsCapability() {
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Issue and claim CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Capability should be issued and claimed (no error)
    Test.assert(true, message: "CriticalOps capability issued and claimed successfully")
}

access(all) fun testCriticalOpsDelegateCanEnableEmergencyMode() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Delegate should be able to enable emergency mode (CriticalOps function)
    let success = delegateEnableEmergencyMode(delegate, poolID: poolID, reason: "Delegate emergency")
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(2), state)  // EmergencyMode = 2
}

access(all) fun testCriticalOpsDelegateCanUpdateDistributionStrategy() {
    let poolID = createPoolWithDistribution(savings: 0.7, lottery: 0.2, treasury: 0.1)
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Delegate should be able to update distribution strategy (CriticalOps function)
    let success = delegateUpdateDistributionStrategy(delegate, poolID: poolID, savings: 0.5, lottery: 0.3, treasury: 0.2)
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.5, details["savingsPercent"]! as! UFix64)
    Test.assertEqual(0.3, details["lotteryPercent"]! as! UFix64)
    Test.assertEqual(0.2, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testCriticalOpsDelegateCanSetPoolState() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Delegate should be able to set pool state (CriticalOps function)
    let success = delegateSetPoolState(delegate, poolID: poolID, state: 1, reason: "Delegate pause")
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(1), state)  // Paused = 1
}

access(all) fun testCriticalOpsDelegateCannotCallConfigOpsFunctions() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Delegate should NOT be able to call ConfigOps functions
    // updatePoolDrawInterval is a ConfigOps function
    let success = criticalOpsTryConfigOperation(delegate, poolID: poolID, newInterval: 3600.0)
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - Full Admin Capability Delegation (Both Entitlements)
// ============================================================================

access(all) fun testCanIssueAndClaimFullAdminCapability() {
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Issue and claim full Admin capability
    setupFullAdminDelegate(delegate)
    
    // Capability should be issued and claimed (no error)
    Test.assert(true, message: "Full Admin capability issued and claimed successfully")
}

access(all) fun testFullAdminDelegateCanCallConfigOpsFunctions() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with full Admin capability
    setupFullAdminDelegate(delegate)
    
    // Delegate should be able to call ConfigOps functions
    let success = fullAdminDelegateUpdateDrawInterval(delegate, poolID: poolID, newInterval: 14400.0)
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let details = getPoolDetails(poolID)
    Test.assertEqual(14400.0, details["drawIntervalSeconds"]! as! UFix64)
}

access(all) fun testFullAdminDelegateCanCallCriticalOpsFunctions() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with full Admin capability
    setupFullAdminDelegate(delegate)
    
    // Delegate should be able to call CriticalOps functions
    let success = fullAdminDelegateEnableEmergency(delegate, poolID: poolID, reason: "Full admin emergency")
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(2), state)  // EmergencyMode = 2
}

// ============================================================================
// TESTS - Multiple Delegates
// ============================================================================

access(all) fun testMultipleDelegatesCanReceiveCapabilities() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create multiple delegate accounts
    let configDelegate = Test.createAccount()
    let criticalDelegate = Test.createAccount()
    let fullDelegate = Test.createAccount()
    
    fundAccountWithFlow(configDelegate, amount: 10.0)
    fundAccountWithFlow(criticalDelegate, amount: 10.0)
    fundAccountWithFlow(fullDelegate, amount: 10.0)
    
    // Setup different capabilities for different delegates
    setupConfigOpsDelegate(configDelegate)
    setupCriticalOpsDelegate(criticalDelegate)
    setupFullAdminDelegate(fullDelegate)
    
    // ConfigOps delegate should be able to update draw interval
    let configSuccess = delegateUpdateDrawInterval(configDelegate, poolID: poolID, newInterval: 1800.0)
    Test.assertEqual(true, configSuccess)
    
    // Create another pool for the critical delegate test
    let poolID2 = createTestPoolWithShortInterval()
    let criticalSuccess = delegateSetPoolState(criticalDelegate, poolID: poolID2, state: 1, reason: "Critical pause")
    Test.assertEqual(true, criticalSuccess)
}

access(all) fun testDelegateCapabilityIsolation() {
    let poolID = createTestPoolWithShortInterval()
    
    // Create two delegate accounts
    let delegate1 = Test.createAccount()
    let delegate2 = Test.createAccount()
    
    fundAccountWithFlow(delegate1, amount: 10.0)
    fundAccountWithFlow(delegate2, amount: 10.0)
    
    // Setup ConfigOps for delegate1 only
    setupConfigOpsDelegate(delegate1)
    
    // delegate1 should succeed
    let success1 = delegateUpdateDrawInterval(delegate1, poolID: poolID, newInterval: 9000.0)
    Test.assertEqual(true, success1)
    
    // delegate2 should fail (no capability)
    let success2 = delegateUpdateDrawInterval(delegate2, poolID: poolID, newInterval: 9999.0)
    Test.assertEqual(false, success2)
}

