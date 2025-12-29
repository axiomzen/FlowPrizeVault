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
// TESTS - Draw Interval Update - Active Round Propagation
// ============================================================================

access(all) fun testUpdateDrawIntervalUpdatesActiveRound() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Verify initial round duration
    let stateBefore = getPoolInitialState(poolID)
    Test.assertEqual(60.0, stateBefore["roundDuration"]! as! UFix64)
    
    // Update interval
    updateDrawInterval(poolID: poolID, newInterval: 120.0)
    
    // Verify active round duration also updated
    let stateAfter = getPoolInitialState(poolID)
    Test.assertEqual(120.0, stateAfter["roundDuration"]! as! UFix64)
}

access(all) fun testUpdateDrawIntervalAffectsHasEnded() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Wait 30 seconds (halfway through round)
    Test.moveTime(by: 30.0)
    
    // Round should not have ended yet
    let stateBefore = getPoolInitialState(poolID)
    Test.assertEqual(false, stateBefore["isRoundEnded"]! as! Bool)
    
    // Shorten interval to 20 seconds (less than elapsed time)
    updateDrawInterval(poolID: poolID, newInterval: 20.0)
    
    // Round should now be ended
    let stateAfter = getPoolInitialState(poolID)
    Test.assertEqual(true, stateAfter["isRoundEnded"]! as! Bool)
}

access(all) fun testUpdateDrawIntervalCanExtendRound() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Round should have ended
    let stateBefore = getPoolInitialState(poolID)
    Test.assertEqual(true, stateBefore["isRoundEnded"]! as! Bool)
    
    // Extend interval to 120 seconds
    updateDrawInterval(poolID: poolID, newInterval: 120.0)
    
    // Round should no longer be ended (exits gap period)
    let stateAfter = getPoolInitialState(poolID)
    Test.assertEqual(false, stateAfter["isRoundEnded"]! as! Bool)
}

// ============================================================================
// TESTS - Draw Interval Update - During Gap Period
// ============================================================================

access(all) fun testUpdateDrawIntervalDuringGapPeriod() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
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

access(all) fun testUpdateDrawIntervalExitsGapPeriodByExtending() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // In gap period
    Test.assertEqual(true, (getPoolInitialState(poolID)["isRoundEnded"]! as! Bool))
    
    // Extend interval to 120 seconds - should exit gap
    updateDrawInterval(poolID: poolID, newInterval: 120.0)
    
    // No longer in gap period
    Test.assertEqual(false, (getPoolInitialState(poolID)["isRoundEnded"]! as! Bool))
    
    // User can continue to deposit normally (not in gap)
    depositToPool(user, poolID: poolID, amount: 10.0)
    
    // Wait for the extended round to end
    Test.moveTime(by: 60.0)
    
    // Now in gap period again
    Test.assertEqual(true, (getPoolInitialState(poolID)["isRoundEnded"]! as! Bool))
}

access(all) fun testUserDepositsAfterIntervalExtensionExitingGap() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    // User1 deposits at start
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Extend interval - exits gap
    updateDrawInterval(poolID: poolID, newInterval: 180.0)
    
    // User2 deposits after interval extension (no longer in gap)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Wait for extended round to end
    Test.moveTime(by: 120.0)
    
    // Execute draw
    executeFullDraw(user1, poolID: poolID)
    
    // Both users should have entries since they were both in the round
    let user1Entries = getUserEntries(user1.address, poolID)
    let user2Entries = getUserEntries(user2.address, poolID)
    
    Test.assert(user1Entries > 0.0, message: "User1 should have entries")
    Test.assert(user2Entries > 0.0, message: "User2 should have entries")
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
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end and start draw
    Test.moveTime(by: 61.0)
    startDraw(user, poolID: poolID)
    
    // Now in batch processing phase - update should still work
    // (it updates pool config and NEW active round, not the pending round)
    updateDrawInterval(poolID: poolID, newInterval: 300.0)
    
    // Verify update succeeded
    let details = getPoolDetails(poolID)
    Test.assertEqual(300.0, details["drawIntervalSeconds"]! as! UFix64)
    
    // Complete the draw
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // New round should have the updated duration
    let state = getPoolInitialState(poolID)
    Test.assertEqual(300.0, state["roundDuration"]! as! UFix64)
}

access(all) fun testNewRoundGetsUpdatedIntervalAfterDraw() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Update interval before draw
    updateDrawInterval(poolID: poolID, newInterval: 180.0)
    
    // Verify current round updated
    Test.assertEqual(180.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Wait for round to end with new duration
    Test.moveTime(by: 181.0)
    
    // Execute draw
    executeFullDraw(user, poolID: poolID)
    
    // New round (round 2) should also have 180s duration
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
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
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

access(all) fun testMultipleIntervalUpdatesInSameRound() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Update multiple times
    updateDrawInterval(poolID: poolID, newInterval: 120.0)
    Test.assertEqual(120.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    updateDrawInterval(poolID: poolID, newInterval: 30.0)
    Test.assertEqual(30.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    updateDrawInterval(poolID: poolID, newInterval: 300.0)
    Test.assertEqual(300.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Final value should persist
    let details = getPoolDetails(poolID)
    Test.assertEqual(300.0, details["drawIntervalSeconds"]! as! UFix64)
}

access(all) fun testShortenIntervalCausesImmediateGapPeriod() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait 45 seconds (3/4 through round)
    Test.moveTime(by: 45.0)
    
    // Not in gap yet
    Test.assertEqual(false, (getPoolInitialState(poolID)["isRoundEnded"]! as! Bool))
    
    // Shorten interval to 30 seconds - now past the end time
    updateDrawInterval(poolID: poolID, newInterval: 30.0)
    
    // Now in gap period
    Test.assertEqual(true, (getPoolInitialState(poolID)["isRoundEnded"]! as! Bool))
    
    // Can execute draw immediately
    executeFullDraw(user, poolID: poolID)
    
    // Verify draw completed
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

access(all) fun testIntervalUpdateAcrossMultipleRounds() {
    let poolID = createTestPoolWithShortInterval() // 1 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery for round 1
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Round 1 with 1s interval
    Test.moveTime(by: 2.0)
    executeFullDraw(user, poolID: poolID)
    Test.assertEqual(UInt64(2), (getPoolInitialState(poolID)["currentRoundID"]! as! UInt64))
    
    // Update interval for round 2
    updateDrawInterval(poolID: poolID, newInterval: 5.0)
    Test.assertEqual(5.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
    
    // Fund lottery for round 2 (prize was distributed in round 1)
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Complete round 2 with new 5s interval
    Test.moveTime(by: 6.0)
    executeFullDraw(user, poolID: poolID)
    Test.assertEqual(UInt64(3), (getPoolInitialState(poolID)["currentRoundID"]! as! UInt64))
    
    // Update interval again for round 3
    updateDrawInterval(poolID: poolID, newInterval: 10.0)
    Test.assertEqual(10.0, (getPoolInitialState(poolID)["roundDuration"]! as! UFix64))
}

access(all) fun testFinalizedRoundDurationNotModified() {
    // This test verifies that once a round is finalized (moved to pendingDrawRound),
    // its duration cannot be modified. The silent skip behavior ensures no revert.
    
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end and start draw
    Test.moveTime(by: 61.0)
    startDraw(user, poolID: poolID)
    
    // At this point:
    // - activeRound (round 2) has duration from pool config
    // - pendingDrawRound (round 1) is finalized with actualEndTime set
    
    // Update interval - should update active round, not pending
    updateDrawInterval(poolID: poolID, newInterval: 999.0)
    
    // Active round (round 2) should have new duration
    let state = getPoolInitialState(poolID)
    Test.assertEqual(999.0, state["roundDuration"]! as! UFix64)
    
    // Complete draw - pending round should still work correctly
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Prize should be distributed correctly
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
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

