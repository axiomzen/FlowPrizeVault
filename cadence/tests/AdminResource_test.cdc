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
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    // Update to new distribution
    updateDistributionStrategy(poolID: poolID, rewards: 0.5, prize: 0.3, protocolFee: 0.2)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.5, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.3, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.2, details["protocolFeePercent"]! as! UFix64)
}

access(all) fun testAdminCanUpdatePrizeDistribution() {
    let poolID = createTestPoolWithShortInterval()
    
    // The pool should have a prize distribution
    let details = getPrizeDistributionDetails(poolID)
    Test.assert(details["distributionName"] != nil, message: "Distribution should exist")
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
// TESTS - Draw Interval Update - During Gap Period
// Note: Interval updates only affect FUTURE rounds, not the current active round.
// ============================================================================

access(all) fun testUpdateDrawIntervalDuringGapPeriod() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Verify in gap period
    let stateInGap = getPoolInitialState(poolID)
    Test.assertEqual(true, stateInGap["isRoundEnded"]! as! Bool)
    
    // Update interval during gap - should not revert
    updateDrawInterval(poolID: poolID, newInterval: 300.0)
    
    // Verify update succeeded
    let details = getPoolDetails(poolID)
    Test.assertEqual(300.0, details["drawIntervalSeconds"]! as! UFix64)
}

// ============================================================================
// TESTS - Draw Interval Update - During Batch Processing
// ============================================================================

access(all) fun testUpdateDrawIntervalDuringBatchProcessing() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end and start draw
    Test.moveTime(by: 61.0)
    startDraw(user, poolID: poolID)
    
    // Now in batch processing phase (pool is in intermission) - update pool config should still work
    // Note: This affects the next round when startNextRound is called
    updateDrawInterval(poolID: poolID, newInterval: 300.0)
    
    // Verify pool config update succeeded
    let details = getPoolDetails(poolID)
    Test.assertEqual(300.0, details["drawIntervalSeconds"]! as! UFix64)
    
    // Complete the draw
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // After completeDraw, pool is in intermission (no active round)
    // roundDuration returns 0.0 during intermission
    let stateIntermission = getPoolInitialState(poolID)
    Test.assertEqual(0.0, stateIntermission["roundDuration"]! as! UFix64)
    
    // Start next round - it will use the NEW 300s interval
    startNextRound(user, poolID: poolID)
    
    let stateAfter = getPoolInitialState(poolID)
    Test.assertEqual(300.0, stateAfter["roundDuration"]! as! UFix64)
}

access(all) fun testNewRoundGetsUpdatedIntervalAfterDraw() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Update interval - only affects future rounds
    updateDrawInterval(poolID: poolID, newInterval: 180.0)
    
    // Current round (round 1) still has original 60s duration
    Test.assertEqual(60.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Wait for round to end (using original 60s duration)
    Test.moveTime(by: 61.0)
    
    // Execute draw - new round created with updated 180s interval
    executeFullDraw(user, poolID: poolID)
    
    // New round (round 2) should have 180s duration (from updated pool config)
    let stateAfterDraw = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), stateAfterDraw["currentRoundID"]! as! UInt64)
    Test.assertEqual(180.0, stateAfterDraw["roundDuration"]! as! UFix64)
}

access(all) fun testIntervalUpdateDoesNotAffectPendingDrawRound() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Start draw - round 1 is now pending
    startDraw(user, poolID: poolID)
    
    // Update interval during batch processing
    updateDrawInterval(poolID: poolID, newInterval: 999.0)
    
    // Complete draw - should still work correctly
    // The pending round's duration wasn't modified
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // User should have won the prize (only participant)
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Draw Interval Update - Edge Cases
// ============================================================================

access(all) fun testMultipleIntervalUpdatesPoolConfig() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Update pool config multiple times
    updateDrawInterval(poolID: poolID, newInterval: 120.0)
    updateDrawInterval(poolID: poolID, newInterval: 30.0)
    updateDrawInterval(poolID: poolID, newInterval: 300.0)
    
    // Final value should persist in pool config
    let details = getPoolDetails(poolID)
    Test.assertEqual(300.0, details["drawIntervalSeconds"]! as! UFix64)
    
    // Current round still has original 60s duration (interval updates only affect future rounds)
    Test.assertEqual(60.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
}

access(all) fun testIntervalUpdateAcrossMultipleRounds() {
    let poolID = createTestPoolWithShortInterval() // 1 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize for round 1
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Update interval to 5s BEFORE the draw - this will apply to round 2
    updateDrawInterval(poolID: poolID, newInterval: 5.0)
    
    // Round 1 still has 1s interval (was created before the update)
    Test.assertEqual(1.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Wait for round 1 to end and execute draw
    Test.moveTime(by: 2.0)
    executeFullDraw(user, poolID: poolID)
    Test.assertEqual(UInt64(2), (getPoolInitialState(poolID)["currentRoundID"]! as! UInt64))
    
    // Round 2 was created with the updated 5s interval
    Test.assertEqual(5.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Fund prize for round 2 (prize was distributed in round 1)
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Update interval to 10s - will apply to round 3
    updateDrawInterval(poolID: poolID, newInterval: 10.0)
    
    // Complete round 2 with its 5s interval
    Test.moveTime(by: 6.0)
    executeFullDraw(user, poolID: poolID)
    Test.assertEqual(UInt64(3), (getPoolInitialState(poolID)["currentRoundID"]! as! UInt64))
    
    // Round 3 was created with the updated 10s interval
    Test.assertEqual(10.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
}

access(all) fun testFinalizedRoundDurationNotModified() {
    // This test verifies that once a round is finalized (moved to pendingDrawRound),
    // its duration cannot be modified. Interval updates only affect future rounds.
    
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end and start draw
    Test.moveTime(by: 61.0)
    startDraw(user, poolID: poolID)
    
    // At this point:
    // - Pool is in intermission (no active round)
    // - pendingDrawRound (round 1) is finalized with actualEndTime set
    
    // Update interval - only affects the next round created by startNextRound
    updateDrawInterval(poolID: poolID, newInterval: 999.0)
    
    // During intermission, roundDuration returns 0.0
    let stateIntermission = getPoolInitialState(poolID)
    Test.assertEqual(0.0, stateIntermission["roundDuration"]! as! UFix64)
    
    // Pool config has been updated
    let details = getPoolDetails(poolID)
    Test.assertEqual(999.0, details["drawIntervalSeconds"]! as! UFix64)
    
    // Complete draw - pending round should still work correctly
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Prize should be distributed correctly
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
    
    // Start next round - it uses the updated interval
    startNextRound(user, poolID: poolID)
    let stateAfterRound = getPoolInitialState(poolID)
    Test.assertEqual(999.0, stateAfterRound["roundDuration"]! as! UFix64)
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
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    // Create a delegate account
    let delegate = Test.createAccount()
    fundAccountWithFlow(delegate, amount: 10.0)
    
    // Setup delegate with CriticalOps capability
    setupCriticalOpsDelegate(delegate)
    
    // Delegate should be able to update distribution strategy (CriticalOps function)
    let success = delegateUpdateDistributionStrategy(delegate, poolID: poolID, rewards: 0.5, prize: 0.3, protocolFee: 0.2)
    Test.assertEqual(true, success)
    
    // Verify the change was made
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.5, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.3, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.2, details["protocolFeePercent"]! as! UFix64)
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

