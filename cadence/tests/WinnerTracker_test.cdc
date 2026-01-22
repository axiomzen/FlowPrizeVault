import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Winner Tracker Presence
// ============================================================================

access(all) fun testPoolWithoutWinnerTrackerHasNone() {
    // Create pool with nil winner tracker (default)
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)
}

access(all) fun testPoolConfigHasNilWinnerTracker() {
    // Verify that default pool creation has nil winner tracker
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let details = getPoolDetails(poolID)
    Test.assert(details["poolID"] != nil, message: "Pool should exist")
    
    // hasWinnerTracker should be false for default pools
    let hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)
}

// ============================================================================
// TESTS - Winner Tracker Integration
// ============================================================================

access(all) fun testWinnerTrackerCanBeQueried() {
    let poolID = createTestPoolWithShortInterval()
    
    // Pool should report no winner tracker
    let hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)
}

access(all) fun testPoolFunctionsWithoutTracker() {
    // Test that pool operates correctly without a winner tracker
    let poolID = createTestPoolWithShortInterval()
    
    // Setup user and execute draw
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 2.0)
    
    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)
    
    // Draw should complete successfully without winner tracker
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist after draw")
}

access(all) fun testMultipleDrawsWithoutTracker() {
    // Test that multiple draws work without a winner tracker
    let poolID = createTestPoolWithShortInterval()
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT * 3.0 + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Execute multiple draws
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 2.0)
    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)
    
    // Second draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 2.0)
    executeFullDraw(deployerAccount, poolID: poolID)
    
    // Pool should still function
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist after multiple draws")
}

