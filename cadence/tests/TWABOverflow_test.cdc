import Test
import "PrizeSavings"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// NORMALIZED TWAB SCALABILITY TESTS
// 
// These tests verify that NORMALIZED TWAB calculations support high TVL
// and long round durations without exceeding UFix64 limits.
// 
// Normalized TWAB:
//   - Formula: TWAB = shares × (elapsed / roundDuration) = "average shares"
//   - Values stay bounded to approximately TVL magnitude
//   - Example: 1M shares × (7d/7d) = 1M
// 
// The normalized calculation keeps values small and predictable while
// preserving relative weights for fair winner selection.
// ============================================================================

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// HELPER: Create pool with specific draw interval
// ============================================================================

access(all) fun createPoolWithDrawInterval(_ intervalSeconds: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_custom_interval.cdc",
        [intervalSeconds],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with custom interval")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

// ============================================================================
// HELPER: Try to execute draw and return success/failure
// ============================================================================

access(all) fun tryProcessDrawBatch(_ poolID: UInt64, limit: Int): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/process_draw_batch.cdc",
        [poolID, limit],
        deployerAccount
    )
    return result.error == nil
}

access(all) fun tryStartDraw(_ poolID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/start_draw.cdc",
        [poolID],
        deployerAccount
    )
    return result.error == nil
}

// ============================================================================
// TEST: Normalized TWAB handles large TVL with long intervals
// 
// 100M FLOW × (3600/3600) = 100M normalized weight
// This verifies the system supports high TVL without issues.
// ============================================================================

access(all) fun testOverflowWithLongIntervalAndModerateTVL() {
    // Create pool with 1-hour (3600 second) interval
    let poolID = createPoolWithDrawInterval(3600.0)
    
    // 100M shares × (3600/3600) = 100M normalized weight
    // System handles this without issues
    
    let numUsers = 2
    let depositPerUser: UFix64 = 50000000.0  // 50 million FLOW each
    
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositPerUser + 100.0)
        depositToPool(user, poolID: poolID, amount: depositPerUser)
        i = i + 1
    }
    
    // Total deposits: 100M FLOW
    // With normalized TWAB: totalWeight ≈ 100M (not 360B)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time past draw interval (1 hour + buffer)
    Test.moveTime(by: 3601.0)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Process batch - NOW WORKS with normalized TWAB!
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    
    // Should succeed with normalized TWAB
    Test.assertEqual(true, batchSuccess)
    log("✓ Normalized TWAB: 100M FLOW over 1-hour interval succeeds")
}

// ============================================================================
// TEST: Normalized TWAB handles single large depositor
// 
// 60M × (3600/3600) = 60M normalized weight
// ============================================================================

access(all) fun testSingleUserTWABOverflow() {
    // Create pool with 1-hour interval
    let poolID = createPoolWithDrawInterval(3600.0)
    
    // 60M shares × (3600/3600) = 60M normalized weight
    let largeDeposit: UFix64 = 60000000.0  // 60 million
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: largeDeposit + 100.0)
    depositToPool(user, poolID: poolID, amount: largeDeposit)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time past draw interval
    Test.moveTime(by: 3601.0)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Process batch - NOW WORKS with normalized TWAB!
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    
    // Should succeed with normalized TWAB
    Test.assertEqual(true, batchSuccess)
    log("✓ Normalized TWAB: single 60M FLOW deposit over 1-hour interval succeeds")
}

// ============================================================================
// TEST: Verify safe operation below overflow threshold
// 
// Confirm the system works when TVL is below threshold.
// With 3600-second interval, max safe total = ~51M shares
// We'll use 40M total (well under threshold)
// ============================================================================

access(all) fun testSafeOperationBelowThreshold() {
    // Create pool with 1-hour interval
    let poolID = createPoolWithDrawInterval(3600.0)
    
    // Max safe shares for 3600 seconds: ~51.2M
    // We'll use 4 users × 10M = 40M total shares (safe)
    // totalWeight = 40M × 3600 = 144B (under 184B max)
    
    let numUsers = 4
    let depositPerUser: UFix64 = 10000000.0  // 10 million each
    
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositPerUser + 100.0)
        depositToPool(user, poolID: poolID, amount: depositPerUser)
        i = i + 1
    }
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time
    Test.moveTime(by: 3601.0)
    
    // Execute full draw - should succeed
    let deployerAccount = getDeployerAccount()
    startDraw(deployerAccount, poolID: poolID)
    processDrawBatch(deployerAccount, poolID: poolID, limit: 1000)
    requestDrawRandomness(deployerAccount, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(deployerAccount, poolID: poolID)
    
    log("✓ Draw succeeded with 40M FLOW TVL (below 51M threshold for 1-hour interval)")
}

// ============================================================================
// TEST: Normalized TWAB handles long interval with multiple users
// 
// 25M × (10000/10000) = 25M normalized weight
// ============================================================================

access(all) fun testSevenDayProxyOverflow() {
    // Use 10000-second interval
    let poolID = createPoolWithDrawInterval(10000.0)
    
    // 25M shares × (10000/10000) = 25M normalized weight
    
    let numUsers = 5
    let depositPerUser: UFix64 = 5000000.0  // 5 million each
    
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositPerUser + 100.0)
        depositToPool(user, poolID: poolID, amount: depositPerUser)
        i = i + 1
    }
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time
    Test.moveTime(by: 10001.0)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Process batch - NOW WORKS with normalized TWAB!
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    
    // Should succeed with normalized TWAB
    Test.assertEqual(true, batchSuccess)
    log("✓ Normalized TWAB: 25M FLOW over 10000-second interval succeeds")
}

// ============================================================================
// TEST: Boundary test - just under limit should work
// ============================================================================

access(all) fun testJustUnderOverflowBoundary() {
    // Use 10000-second interval
    let poolID = createPoolWithDrawInterval(10000.0)
    
    // Max safe for 10000 seconds: 184B / 10000 ≈ 18.4M shares
    // We'll use 15M total (well under limit)
    // totalWeight = 15M × 10000 = 150B < 184B max (safe!)
    
    let numUsers = 3
    let depositPerUser: UFix64 = 5000000.0  // 5 million each = 15M total
    
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositPerUser + 100.0)
        depositToPool(user, poolID: poolID, amount: depositPerUser)
        i = i + 1
    }
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time
    Test.moveTime(by: 10001.0)
    
    // Execute full draw - should succeed
    let deployerAccount = getDeployerAccount()
    startDraw(deployerAccount, poolID: poolID)
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    
    // Should succeed since we're under the limit
    Test.assertEqual(true, batchSuccess)
    log("✓ Draw succeeded at 15M shares for 10000-second interval (under 18.4M limit)")
}

// ============================================================================
// TEST: Normalized TWAB handles high TVL with long intervals
// ============================================================================

access(all) fun testJustOverOverflowBoundary() {
    // Use 10000-second interval
    let poolID = createPoolWithDrawInterval(10000.0)
    
    // 20M shares × (10000/10000) = 20M normalized weight
    
    let numUsers = 4
    let depositPerUser: UFix64 = 5000000.0  // 5 million each = 20M total
    
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositPerUser + 100.0)
        depositToPool(user, poolID: poolID, amount: depositPerUser)
        i = i + 1
    }
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time
    Test.moveTime(by: 10001.0)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Process batch - NOW WORKS with normalized TWAB!
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    
    // Should succeed with normalized TWAB
    Test.assertEqual(true, batchSuccess)
    log("✓ Normalized TWAB: 20M shares for 10000-second interval succeeds")
}

