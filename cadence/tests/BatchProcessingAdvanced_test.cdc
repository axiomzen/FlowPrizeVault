import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Batch Cursor Edge Cases
// ============================================================================

access(all) fun testBatchStartsAtCursorZero() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 3 participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    setupUserWithFundsAndCollection(user3, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(user1, poolID: poolID)
    
    // Verify batch is in progress (cursor starts at 0)
    let statusAfterStart = getDrawStatus(poolID)
    Test.assert(statusAfterStart["isBatchInProgress"]! as! Bool, message: "Batch should be in progress")
    Test.assertEqual(false, statusAfterStart["isBatchComplete"]! as! Bool)
    
    // Process first user only (limit=1)
    processDrawBatch(user1, poolID: poolID, limit: 1)
    
    // Batch should still not be complete (2 more users)
    let statusAfter1 = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfter1["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchProcessesExactlyLimitUsers() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 5 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process exactly 2 users
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    
    // Should not be complete (3 users remaining)
    let statusAfter2 = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfter2["isBatchComplete"]! as! Bool)
    
    // Process 2 more
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    
    // Should still not be complete (1 user remaining)
    let statusAfter4 = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfter4["isBatchComplete"]! as! Bool)
    
    // Process final user
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // Now should be complete
    let statusFinal = getDrawStatus(poolID)
    Test.assertEqual(true, statusFinal["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchProcessesSingleUserAtEnd() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 4 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 4 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process in batches of 3
    startDraw(users[0], poolID: poolID)
    processDrawBatch(users[0], poolID: poolID, limit: 3)
    
    // Should not be complete (1 user remaining)
    let statusBefore = getDrawStatus(poolID)
    Test.assertEqual(false, statusBefore["isBatchComplete"]! as! Bool)
    
    // Process final single user
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // Now complete
    let statusAfter = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchExactlyDivisibleByLimit() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 4 participants (divisible by 2)
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 4 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process in batches of 2 (should take exactly 2 batches)
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    let statusAfter1 = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfter1["isBatchComplete"]! as! Bool)
    
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    let statusAfter2 = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter2["isBatchComplete"]! as! Bool)
}

// ============================================================================
// TESTS - Large Scale Batch Processing
// ============================================================================

access(all) fun testBatchWith10Users() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 10 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 10 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Execute full draw with batch processing
    executeFullDraw(users[0], poolID: poolID)
    
    // Verify one winner received prize
    var totalPrizes: UFix64 = 0.0
    for user in users {
        let prizes = getUserPrizes(user.address, poolID)
        totalPrizes = totalPrizes + prizes["totalEarnedPrizes"]!
    }
    
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}

access(all) fun testBatchWith20Users() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 20 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 20 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Execute full draw
    executeFullDraw(users[0], poolID: poolID)
    
    // Verify total prizes
    var totalPrizes: UFix64 = 0.0
    for user in users {
        let prizes = getUserPrizes(user.address, poolID)
        totalPrizes = totalPrizes + prizes["totalEarnedPrizes"]!
    }
    
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}

access(all) fun testManySmallBatches() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 5 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process one at a time (5 batches of 1)
    var batchCount = 0
    while batchCount < 5 {
        processDrawBatch(users[0], poolID: poolID, limit: 1)
        batchCount = batchCount + 1
    }
    
    // Should be complete after 5 batches
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchComplete"]! as! Bool)
    
    // Complete the draw
    requestDrawRandomness(users[0], poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(users[0], poolID: poolID)
    
    // Verify prize distributed
    var totalPrizes: UFix64 = 0.0
    for user in users {
        let prizes = getUserPrizes(user.address, poolID)
        totalPrizes = totalPrizes + prizes["totalEarnedPrizes"]!
    }
    
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}

// ============================================================================
// TESTS - Weight Calculation During Batch
// ============================================================================

access(all) fun testAllUsersWithEqualDepositsGetEqualWeights() {
    let poolID = createTestPoolWithMediumInterval() // 60s for more accurate TWAB
    let depositAmount: UFix64 = 100.0
    
    // Setup 3 participants with equal deposits at same time
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user3, amount: depositAmount + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    depositToPool(user3, poolID: poolID, amount: depositAmount)
    
    // All users should have approximately equal entries
    let entries1 = getUserEntries(user1.address, poolID)
    let entries2 = getUserEntries(user2.address, poolID)
    let entries3 = getUserEntries(user3.address, poolID)
    
    // Allow small tolerance for transaction timing differences
    let tolerance: UFix64 = 5.0
    
    let diff12 = entries1 > entries2 ? entries1 - entries2 : entries2 - entries1
    let diff23 = entries2 > entries3 ? entries2 - entries3 : entries3 - entries2
    
    Test.assert(diff12 < tolerance, message: "User1 and User2 should have similar entries")
    Test.assert(diff23 < tolerance, message: "User2 and User3 should have similar entries")
}

access(all) fun testLargerDepositGetsMoreWeight() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup users with different deposit amounts
    let smallUser = Test.createAccount()
    let largeUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(smallUser, amount: 60.0)
    setupUserWithFundsAndCollection(largeUser, amount: 210.0)
    
    depositToPool(smallUser, poolID: poolID, amount: 50.0)
    depositToPool(largeUser, poolID: poolID, amount: 200.0)
    
    // Large user should have more entries (proportional to deposit)
    let smallEntries = getUserEntries(smallUser.address, poolID)
    let largeEntries = getUserEntries(largeUser.address, poolID)
    
    // Large deposit is 4x small, entries should be ~4x higher
    let ratio = largeEntries / smallEntries
    
    // Test within limits because each deposit happens at a different block and the timeStamp is slightly variable
    Test.assert(
        ratio > 3.7 && ratio < 4.3,
        message: "Large user should have ~4x entries. Got ratio: ".concat(ratio.toString())
    )
}

access(all) fun testEarlierDepositGetsMoreWeight() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // User1 deposits at start
    let earlyUser = Test.createAccount()
    setupUserWithFundsAndCollection(earlyUser, amount: depositAmount + 10.0)
    depositToPool(earlyUser, poolID: poolID, amount: depositAmount)
    
    // Advance to 50% of round
    Test.moveTime(by: 30.0)
    
    // User2 deposits at 50%
    let lateUser = Test.createAccount()
    setupUserWithFundsAndCollection(lateUser, amount: depositAmount + 10.0)
    depositToPool(lateUser, poolID: poolID, amount: depositAmount)
    
    // Early user should have more entries
    let earlyEntries = getUserEntries(earlyUser.address, poolID)
    let lateEntries = getUserEntries(lateUser.address, poolID)
    
    Test.assert(
        earlyEntries > lateEntries * 1.5,
        message: "Early user should have significantly more entries. Early: "
            .concat(earlyEntries.toString())
            .concat(", Late: ").concat(lateEntries.toString())
    )
}

// ============================================================================
// TESTS - Batch Processing State Validation
// ============================================================================

access(all) fun testBatchStateAfterStartDraw() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Check state before startDraw
    let statusBefore = getDrawStatus(poolID)
    Test.assertEqual(false, statusBefore["isBatchInProgress"]! as! Bool)
    Test.assertEqual(false, statusBefore["isPendingDrawInProgress"]! as! Bool)
    
    // Start draw
    startDraw(user, poolID: poolID)
    
    // Check state after startDraw
    let statusAfter = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter["isBatchInProgress"]! as! Bool)
    Test.assertEqual(true, statusAfter["isPendingDrawInProgress"]! as! Bool)
    Test.assertEqual(false, statusAfter["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchStateAfterProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process
    startDraw(user, poolID: poolID)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    
    // Check state after processing
    let statusAfter = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter["isBatchComplete"]! as! Bool)
    Test.assertEqual(false, statusAfter["isDrawInProgress"]! as! Bool) // Not until randomness requested
}

access(all) fun testBatchStateAfterRandomnessRequest() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw, process, and request randomness
    startDraw(user, poolID: poolID)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user, poolID: poolID)
    
    // Check state after randomness request
    let statusAfter = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter["isDrawInProgress"]! as! Bool)
    Test.assertEqual(true, statusAfter["isReadyForCompletion"]! as! Bool)
}

// ============================================================================
// TESTS - Interrupted Batch Processing
// ============================================================================

access(all) fun testPartialBatchStateIsValid() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 5 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process only 2 of 5 users
    startDraw(users[0], poolID: poolID)
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    
    // State should show batch in progress but not complete
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchInProgress"]! as! Bool)
    Test.assertEqual(false, status["isBatchComplete"]! as! Bool)
    Test.assertEqual(true, status["isPendingDrawInProgress"]! as! Bool)
    
    // Can still process remaining
    processAllDrawBatches(users[0], poolID: poolID, batchSize: 1000)
    
    let statusFinal = getDrawStatus(poolID)
    Test.assertEqual(true, statusFinal["isBatchComplete"]! as! Bool)
}

access(all) fun testResumeBatchAfterUserDeposit() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 3 initial participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 3 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process 1 of 3 users
    startDraw(users[0], poolID: poolID)
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // New user deposits (will be in new round, not in current batch)
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(newUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Continue batch processing
    processAllDrawBatches(users[0], poolID: poolID, batchSize: 1000)
    
    // Batch should be complete (only original 3 users)
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchComplete"]! as! Bool)
    
    // Complete draw
    requestDrawRandomness(users[0], poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(users[0], poolID: poolID)
    
    // New user should NOT have won (wasn't in the batch)
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
}

access(all) fun testResumeBatchAfterUserWithdrawal() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 3 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 3 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process 1 of 3 users
    startDraw(users[0], poolID: poolID)
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // User2 withdraws during batch processing
    withdrawFromPool(users[1], poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Continue batch processing (user2 still in list but may have different weight)
    processAllDrawBatches(users[0], poolID: poolID, batchSize: 1000)
    
    // Batch should be complete
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchComplete"]! as! Bool)
    
    // Complete draw
    requestDrawRandomness(users[0], poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(users[0], poolID: poolID)
    
    // Draw should complete successfully
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

// ============================================================================
// TESTS - Edge Cases with Zero/Empty State
// ============================================================================

access(all) fun testBatchWithLimitZeroProcessesNothing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(user, poolID: poolID)
    
    // Process with limit 0
    processDrawBatch(user, poolID: poolID, limit: 0)
    
    // Batch should still be in progress (nothing processed)
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchInProgress"]! as! Bool)
    Test.assertEqual(false, status["isBatchComplete"]! as! Bool)
    
    // Now process with real limit
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    
    // Should complete
    let statusFinal = getDrawStatus(poolID)
    Test.assertEqual(true, statusFinal["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchReturnsCorrectRemainingCount() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 5 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
        depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process batches and verify remaining count decreases
    // Note: We can't directly get the return value in test framework,
    // but we can verify batch state transitions correctly
    
    processDrawBatch(users[0], poolID: poolID, limit: 2) // 3 remaining
    let status1 = getDrawStatus(poolID)
    Test.assertEqual(false, status1["isBatchComplete"]! as! Bool)
    
    processDrawBatch(users[0], poolID: poolID, limit: 2) // 1 remaining
    let status2 = getDrawStatus(poolID)
    Test.assertEqual(false, status2["isBatchComplete"]! as! Bool)
    
    processDrawBatch(users[0], poolID: poolID, limit: 1) // 0 remaining
    let status3 = getDrawStatus(poolID)
    Test.assertEqual(true, status3["isBatchComplete"]! as! Bool)
}

// ============================================================================
// TESTS - Batch Processing with Different Pool Configurations
// ============================================================================

access(all) fun testBatchProcessingWithMediumInterval() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Setup 3 participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    setupUserWithFundsAndCollection(user3, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time past 60s
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Execute full draw with batch processing
    executeFullDraw(user1, poolID: poolID)
    
    // Verify prize distributed
    let prizes1 = getUserPrizes(user1.address, poolID)["totalEarnedPrizes"]!
    let prizes2 = getUserPrizes(user2.address, poolID)["totalEarnedPrizes"]!
    let prizes3 = getUserPrizes(user3.address, poolID)["totalEarnedPrizes"]!
    let totalPrizes = prizes1 + prizes2 + prizes3
    
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}

