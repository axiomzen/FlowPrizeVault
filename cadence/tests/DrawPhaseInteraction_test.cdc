import Test
import "PrizeSavings"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Deposits During Each Draw Phase
// ============================================================================

access(all) fun testDepositDuringPhase1StartDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial participant
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Phase 1: startDraw() called
    startDraw(existingUser, poolID: poolID)
    
    // New user deposits right after startDraw
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 10.0)
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Verify deposit succeeded
    let balance = getUserPoolBalance(newUser.address, poolID)
    Test.assert(balance["deposits"]! > 0.0, message: "New user should have balance after Phase 1 deposit")
    
    // Complete the draw
    processAllDrawBatches(existingUser, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(existingUser, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(existingUser, poolID: poolID)
    
    // New user should NOT have won (deposited in new round)
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
    
    // Existing user should have won
    let existingPrizes = getUserPrizes(existingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, existingPrizes["totalEarnedPrizes"]!)
}

access(all) fun testDepositDuringPhase2BatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup 3 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 3 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
        depositToPool(user, poolID: poolID, amount: depositAmount)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process first batch (1 of 3 users)
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // New user deposits during batch processing
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 10.0)
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Verify deposit succeeded
    let balance = getUserPoolBalance(newUser.address, poolID)
    Test.assert(balance["deposits"]! > 0.0, message: "New user should have balance after Phase 2 deposit")
    
    // Complete batch processing and draw
    processAllDrawBatches(users[0], poolID: poolID, batchSize: 1000)
    requestDrawRandomness(users[0], poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(users[0], poolID: poolID)
    
    // New user should NOT have won (wasn't in batch)
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
}

access(all) fun testDepositDuringPhase3Randomness() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup participant
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Phases 1-3
    startDraw(existingUser, poolID: poolID)
    processAllDrawBatches(existingUser, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(existingUser, poolID: poolID)
    
    // New user deposits after randomness requested (waiting for completion)
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 10.0)
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Verify deposit succeeded
    let balance = getUserPoolBalance(newUser.address, poolID)
    Test.assert(balance["deposits"]! > 0.0, message: "New user should have balance after Phase 3 deposit")
    
    // Complete draw
    commitBlocksForRandomness()
    completeDraw(existingUser, poolID: poolID)
    
    // New user should NOT have won
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Withdrawals During Each Draw Phase
// ============================================================================

access(all) fun testWithdrawDuringPhase1StartDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 50.0
    
    // Setup two participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Phase 1: startDraw() called
    startDraw(user1, poolID: poolID)
    
    // User2 withdraws right after startDraw
    withdrawFromPool(user2, poolID: poolID, amount: withdrawAmount)
    
    // Verify withdrawal succeeded
    let balanceAfter = getUserPoolBalance(user2.address, poolID)
    Test.assertEqual(depositAmount - withdrawAmount, balanceAfter["deposits"]!)
    
    // Complete the draw
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    
    // Draw should complete successfully
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

access(all) fun testWithdrawDuringPhase2BatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup 3 participants
    var users: [Test.TestAccount] = []
    var i = 0
    while i < 3 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
        depositToPool(user, poolID: poolID, amount: depositAmount)
        users.append(user)
        i = i + 1
    }
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process first batch
    processDrawBatch(users[0], poolID: poolID, limit: 1)
    
    // User1 withdraws during batch processing
    withdrawFromPool(users[1], poolID: poolID, amount: 50.0)
    
    // Verify withdrawal succeeded
    let balanceAfter = getUserPoolBalance(users[1].address, poolID)
    Test.assertEqual(50.0, balanceAfter["deposits"]!)
    
    // Complete batch and draw
    processAllDrawBatches(users[0], poolID: poolID, batchSize: 1000)
    requestDrawRandomness(users[0], poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(users[0], poolID: poolID)
    
    // Draw should complete
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

access(all) fun testWithdrawDuringPhase3Randomness() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Phases 1-3
    startDraw(user1, poolID: poolID)
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user1, poolID: poolID)
    
    // User2 withdraws after randomness requested
    withdrawFromPool(user2, poolID: poolID, amount: 50.0)
    
    // Complete draw
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    
    // Draw should complete successfully
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

// ============================================================================
// TESTS - New User Joins During Draw
// ============================================================================

access(all) fun testNewUserJoinsDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial participant
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(existingUser, poolID: poolID)
    
    // New user joins mid-draw
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 10.0)
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Complete draw
    processAllDrawBatches(existingUser, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(existingUser, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(existingUser, poolID: poolID)
    
    // New user should be in the new round with entries
    let newUserEntries = getUserEntries(newUser.address, poolID)
    Test.assert(newUserEntries > 0.0, message: "New user should have entries in new round")
    
    // New user should NOT have won current draw
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
}

access(all) fun testUserLeavesCompletelyDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two participants
    let stayingUser = Test.createAccount()
    let leavingUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(stayingUser, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(leavingUser, amount: depositAmount + 10.0)
    
    depositToPool(stayingUser, poolID: poolID, amount: depositAmount)
    depositToPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(stayingUser, poolID: poolID)
    
    // Leaving user withdraws everything during draw
    withdrawFromPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Verify leaving user has 0 balance
    let leavingBalance = getUserPoolBalance(leavingUser.address, poolID)
    Test.assertEqual(0.0, leavingBalance["deposits"]!)
    
    // Complete draw
    processAllDrawBatches(stayingUser, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(stayingUser, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(stayingUser, poolID: poolID)
    
    // Draw should complete
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
}

// ============================================================================
// TESTS - Isolation Between Users During Draw
// ============================================================================

access(all) fun testUserNotAffectedByOthersDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup 3 participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount * 2.0 + 10.0)
    setupUserWithFundsAndCollection(user3, amount: depositAmount * 2.0 + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    depositToPool(user3, poolID: poolID, amount: depositAmount)
    
    // Get user1's entries before draw
    let user1EntriesBefore = getUserEntries(user1.address, poolID)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(user1, poolID: poolID)
    
    // User2 withdraws and re-deposits during draw
    withdrawFromPool(user2, poolID: poolID, amount: 50.0)
    depositToPool(user2, poolID: poolID, amount: 50.0)
    
    // User3 makes additional deposit during draw
    depositToPool(user3, poolID: poolID, amount: depositAmount)
    
    // Complete draw
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    requestDrawRandomness(user1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    
    // User1 should still have entries in new round (unaffected by others)
    let user1EntriesAfter = getUserEntries(user1.address, poolID)
    Test.assert(user1EntriesAfter > 0.0, message: "User1 should have entries after draw")
}

// ============================================================================
// TESTS - Multiple Users Active During Different Phases
// ============================================================================

access(all) fun testDifferentUsersDifferentPhases() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount * 2.0 + 20.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount * 2.0 + 20.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Phase 1: Start draw, user1 adds more
    startDraw(user1, poolID: poolID)
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    
    // Phase 2: Batch processing, user2 withdraws some
    processDrawBatch(user1, poolID: poolID, limit: 1)
    withdrawFromPool(user2, poolID: poolID, amount: 50.0)
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    
    // Phase 3: Request randomness, user1 withdraws
    requestDrawRandomness(user1, poolID: poolID)
    withdrawFromPool(user1, poolID: poolID, amount: 50.0)
    
    // Phase 4: Complete draw
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    
    // Draw should complete successfully
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
    
    // Both users should have entries in new round
    let user1Entries = getUserEntries(user1.address, poolID)
    let user2Entries = getUserEntries(user2.address, poolID)
    
    Test.assert(user1Entries > 0.0, message: "User1 should have entries")
    Test.assert(user2Entries > 0.0, message: "User2 should have entries")
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testMultipleDepositsFromSameUserDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 25.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(user, poolID: poolID)
    
    // Multiple deposits during draw phases
    depositToPool(user, poolID: poolID, amount: depositAmount)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    requestDrawRandomness(user, poolID: poolID)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Complete draw
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Verify final balance (initial + 4 more during draw + prize)
    let balance = getUserPoolBalance(user.address, poolID)
    let expectedBase = depositAmount * 5.0 // 5 deposits of 25
    let expectedWithPrize = expectedBase + DEFAULT_PRIZE_AMOUNT
    
    let tolerance: UFix64 = 0.1
    let difference = balance["deposits"]! > expectedWithPrize 
        ? balance["deposits"]! - expectedWithPrize 
        : expectedWithPrize - balance["deposits"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should reflect all deposits + prize. Got: ".concat(balance["deposits"]!.toString())
    )
}

access(all) fun testMultipleWithdrawalsFromSameUserDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 10.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(user, poolID: poolID)
    
    // Multiple withdrawals during draw phases
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    requestDrawRandomness(user, poolID: poolID)
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Complete draw
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Verify final balance (initial - 4 withdrawals + prize)
    let balance = getUserPoolBalance(user.address, poolID)
    let expectedBase = depositAmount - (withdrawAmount * 4.0) // 60
    let expectedWithPrize = expectedBase + DEFAULT_PRIZE_AMOUNT // 65
    
    let tolerance: UFix64 = 0.1
    let difference = balance["deposits"]! > expectedWithPrize 
        ? balance["deposits"]! - expectedWithPrize 
        : expectedWithPrize - balance["deposits"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should be ~65. Got: ".concat(balance["deposits"]!.toString())
    )
}

access(all) fun testDrawCompletesWithOnlyOriginalParticipants() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup 2 initial participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Full draw process
    startDraw(user1, poolID: poolID)
    
    // New users join during various phases (but not eligible)
    let lateUser1 = Test.createAccount()
    setupUserWithFundsAndCollection(lateUser1, amount: depositAmount + 10.0)
    depositToPool(lateUser1, poolID: poolID, amount: depositAmount)
    
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    
    let lateUser2 = Test.createAccount()
    setupUserWithFundsAndCollection(lateUser2, amount: depositAmount + 10.0)
    depositToPool(lateUser2, poolID: poolID, amount: depositAmount)
    
    requestDrawRandomness(user1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    
    // Prize should only go to original participants
    let user1Prizes = getUserPrizes(user1.address, poolID)["totalEarnedPrizes"]!
    let user2Prizes = getUserPrizes(user2.address, poolID)["totalEarnedPrizes"]!
    let late1Prizes = getUserPrizes(lateUser1.address, poolID)["totalEarnedPrizes"]!
    let late2Prizes = getUserPrizes(lateUser2.address, poolID)["totalEarnedPrizes"]!
    
    let originalTotalPrizes = user1Prizes + user2Prizes
    let lateTotalPrizes = late1Prizes + late2Prizes
    
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, originalTotalPrizes)
    Test.assertEqual(0.0, lateTotalPrizes)
}

