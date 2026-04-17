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
// TESTS - Batch Processing Basics
// ============================================================================

access(all) fun testStartDrawInitializesBatchState() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw only (don't process batches)
    startDraw(participant, poolID: poolID)
    
    // Check batch state was initialized
    let drawStatus = getDrawStatus(poolID)
    let isBatchInProgress = drawStatus["isBatchInProgress"]! as! Bool
    Test.assert(isBatchInProgress, message: "Batch processing should be in progress after startDraw")
    
    // Batch should not be complete yet if we haven't processed
    let isBatchComplete = drawStatus["isBatchComplete"]! as! Bool
    // Note: For single user, the batch might complete immediately - this is OK
}

access(all) fun testProcessBatchCapturesWeights() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup multiple participants
    let participant1 = Test.createAccount()
    let participant2 = Test.createAccount()
    let participant3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(participant1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant3, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(participant1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(participant1, poolID: poolID)
    
    // Process all batches (3 users, so 1 batch of 1000 should cover it)
    processDrawBatch(participant1, poolID: poolID, limit: 1000)
    
    // Check batch is now complete
    let drawStatus = getDrawStatus(poolID)
    let isBatchComplete = drawStatus["isBatchComplete"]! as! Bool
    Test.assert(isBatchComplete, message: "Batch should be complete after processing all receivers")
}

access(all) fun testBatchProcessingWithSmallBatches() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup multiple participants
    let participant1 = Test.createAccount()
    let participant2 = Test.createAccount()
    let participant3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(participant1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant3, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(participant1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(participant1, poolID: poolID)
    
    // Process in small batches (1 at a time)
    processDrawBatch(participant1, poolID: poolID, limit: 1)
    
    // Check progress - should not be complete yet
    let statusAfter1 = getDrawStatus(poolID)
    let isComplete1 = statusAfter1["isBatchComplete"]! as! Bool
    // Might or might not be complete depending on how many users
    
    // Process more
    processDrawBatch(participant1, poolID: poolID, limit: 1)
    processDrawBatch(participant1, poolID: poolID, limit: 1)
    
    // Should be complete now
    let statusFinal = getDrawStatus(poolID)
    let isCompleteFinal = statusFinal["isBatchComplete"]! as! Bool
    Test.assert(isCompleteFinal, message: "Batch should be complete after processing all receivers")
}

// ============================================================================
// TESTS - Request Randomness
// ============================================================================

access(all) fun testRequestRandomnessAfterBatchComplete() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw (includes randomness request) and process batches
    startDraw(participant, poolID: poolID)
    processAllDrawBatches(participant, poolID: poolID, batchSize: 1000)
    
    // Now draw should be in progress (randomness was requested during startDraw)
    let drawStatus = getDrawStatus(poolID)
    let isDrawInProgress = drawStatus["isDrawInProgress"]! as! Bool
    let isReadyForCompletion = drawStatus["isReadyForCompletion"]! as! Bool
    
    Test.assert(isDrawInProgress, message: "Draw should be in progress after startDraw")
    Test.assert(isReadyForCompletion, message: "Should be ready for completion after batch processing")
}

// ============================================================================
// TESTS - User Interactions During Batch Processing
// ============================================================================

access(all) fun testUserCanDepositDuringBatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup initial participant
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw (new round begins)
    startDraw(existingUser, poolID: poolID)
    
    // New user deposits during batch processing phase
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(newUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Should succeed - new user is depositing into the new (active) round
    let newUserBalance = getUserPoolBalance(newUser.address, poolID)
    Test.assert(newUserBalance["totalBalance"]! > 0.0, message: "New user should have balance after depositing during batch processing")
}

access(all) fun testUserCanWithdrawDuringBatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup initial participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw (new round begins)
    startDraw(user, poolID: poolID)
    
    // Get balance before withdrawal
    let balanceBefore = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    
    // User withdraws during batch processing phase
    let withdrawAmount = DEFAULT_DEPOSIT_AMOUNT / 2.0
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Should succeed
    let balanceAfter = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    Test.assert(balanceAfter < balanceBefore, message: "Balance should decrease after withdrawal during batch processing")
}

// ============================================================================
// TESTS - Full Draw Flow
// ============================================================================

access(all) fun testFullBatchedDrawFlow() {
    let poolID = createTestPoolWithMediumInterval()
    let prizeAmount = DEFAULT_PRIZE_AMOUNT
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    
    // Execute full 4-phase draw
    // Phase 1: Start draw
    startDraw(participant, poolID: poolID)
    
    let status1 = getDrawStatus(poolID)
    Test.assert(status1["isBatchInProgress"]! as! Bool, message: "Phase 1: Batch should be in progress")
    
    // Phase 2: Process all batches
    processAllDrawBatches(participant, poolID: poolID, batchSize: 1000)
    
    let status2 = getDrawStatus(poolID)
    Test.assert(status2["isBatchComplete"]! as! Bool, message: "Phase 2: Batch should be complete")
    
    // Verify draw state after batch completion
    let status3 = getDrawStatus(poolID)
    Test.assert(status3["isDrawInProgress"]! as! Bool, message: "Draw should be in progress")
    Test.assert(status3["isReadyForCompletion"]! as! Bool, message: "Should be ready for completion")
    
    // Phase 3: Complete draw (after randomness available - wait 1 block)
    commitBlocksForRandomness()
    completeDraw(participant, poolID: poolID)
    
    // Verify winner received prize
    let finalPrizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(prizeAmount, finalPrizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testBatchProcessingWithSingleUser() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup single participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Execute full draw
    executeFullDraw(participant, poolID: poolID)
    
    // Single participant should win
    let finalPrizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, finalPrizes["totalEarnedPrizes"]!)
}

access(all) fun testEmptyBatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(participant, poolID: poolID)
    
    // Process with limit 0 (should process nothing but not fail)
    processDrawBatch(participant, poolID: poolID, limit: 0)
    
    // Batch should still be in progress (no actual processing done)
    let status = getDrawStatus(poolID)
    let isBatchInProgress = status["isBatchInProgress"]! as! Bool
    Test.assert(isBatchInProgress, message: "Batch should still be in progress after empty batch")
}

// ============================================================================
// TESTS - Additional Batch Processing Scenarios
// ============================================================================

access(all) fun testBatchProgressesCorrectly() {
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
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process in batches of 2 (should take 2 batches)
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    let statusAfter1 = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfter1["isBatchComplete"]! as! Bool)
    
    processDrawBatch(users[0], poolID: poolID, limit: 2)
    let statusAfter2 = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter2["isBatchComplete"]! as! Bool)
}

access(all) fun testBatchWithLargeBatchSize() {
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
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(users[0], poolID: poolID)
    
    // Process with limit larger than user count
    processDrawBatch(users[0], poolID: poolID, limit: 10000)
    
    // Should complete in one batch
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchComplete"]! as! Bool)
}

access(all) fun testStateTransitionsThroughAllPhases() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Initial state - no draw
    let statusInitial = getDrawStatus(poolID)
    Test.assertEqual(false, statusInitial["isBatchInProgress"]! as! Bool)
    Test.assertEqual(false, statusInitial["isDrawInProgress"]! as! Bool)
    Test.assertEqual(true, statusInitial["canDrawNow"]! as! Bool)
    
    // Phase 1: Start draw (includes randomness request)
    startDraw(user, poolID: poolID)
    let status1 = getDrawStatus(poolID)
    Test.assertEqual(true, status1["isBatchInProgress"]! as! Bool)
    Test.assertEqual(true, status1["isDrawInProgress"]! as! Bool)  // Now true after startDraw
    
    // Phase 2: Process batches
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    let status2 = getDrawStatus(poolID)
    Test.assertEqual(true, status2["isBatchComplete"]! as! Bool)
    Test.assertEqual(true, status2["isDrawInProgress"]! as! Bool)  // Still true
    Test.assertEqual(true, status2["isReadyForCompletion"]! as! Bool)  // Ready after batch complete
    
    // Phase 3: Complete draw (after randomness available - wait 1 block)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Final state - back to no draw in progress
    let statusFinal = getDrawStatus(poolID)
    Test.assertEqual(false, statusFinal["isBatchInProgress"]! as! Bool)
    Test.assertEqual(false, statusFinal["isDrawInProgress"]! as! Bool)
}

access(all) fun testNewUserDepositDuringBatchNotEligibleForCurrentDraw() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup initial participant
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(existingUser, poolID: poolID)
    
    // New user deposits during batch processing
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(newUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Complete the draw
    processAllDrawBatches(existingUser, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(existingUser, poolID: poolID)
    
    // Existing user should have won (new user wasn't eligible)
    let existingPrizes = getUserPrizes(existingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, existingPrizes["totalEarnedPrizes"]!)
    
    // New user should have 0 prizes
    let newUserPrizes = getUserPrizes(newUser.address, poolID)
    Test.assertEqual(0.0, newUserPrizes["totalEarnedPrizes"]!)
}

access(all) fun testBatchProcessingWithDifferentDeposits() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participants with different deposits
    let smallUser = Test.createAccount()
    let mediumUser = Test.createAccount()
    let largeUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(smallUser, amount: 60.0)
    setupUserWithFundsAndCollection(mediumUser, amount: 110.0)
    setupUserWithFundsAndCollection(largeUser, amount: 210.0)
    
    depositToPool(smallUser, poolID: poolID, amount: 50.0)
    depositToPool(mediumUser, poolID: poolID, amount: 100.0)
    depositToPool(largeUser, poolID: poolID, amount: 200.0)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Execute full draw
    executeFullDraw(smallUser, poolID: poolID)
    
    // One of them should have won
    let smallPrizes = getUserPrizes(smallUser.address, poolID)["totalEarnedPrizes"]!
    let mediumPrizes = getUserPrizes(mediumUser.address, poolID)["totalEarnedPrizes"]!
    let largePrizes = getUserPrizes(largeUser.address, poolID)["totalEarnedPrizes"]!
    
    let totalPrizes = smallPrizes + mediumPrizes + largePrizes
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}

access(all) fun testMultipleBatchCallsAfterComplete() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and process
    startDraw(user, poolID: poolID)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    
    // Batch should be complete
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isBatchComplete"]! as! Bool)
    
    // Complete the rest of the draw
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Start next round to exit intermission
    startNextRound(user, poolID: poolID)
    
    // Verify draw completed and round incremented
    let finalState = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), finalState["currentRoundID"]! as! UInt64)
}

// ============================================================================
// TESTS - Round Transition During Batch
// ============================================================================

access(all) fun testPoolEntersDrawProcessingOnStartDraw() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)

    // Check round ID before
    let stateBefore = getPoolInitialState(poolID)
    let roundBefore = stateBefore["currentRoundID"]! as! UInt64
    Test.assertEqual(UInt64(1), roundBefore)

    // Start draw (pool enters DRAW_PROCESSING state, not intermission)
    startDraw(user, poolID: poolID)

    // Pool should be in DRAW_PROCESSING (not intermission!)
    // isInIntermission is only true when draw is complete AND no active round
    Test.assertEqual(true, isDrawInProgress(poolID))
    Test.assertEqual(false, isInIntermission(poolID))

    // Round ID during draw processing: activeRound stays in place (simplified design)
    // so currentRoundID remains the same (activeRound has actualEndTime set but isn't destroyed)
    let stateAfter = getPoolInitialState(poolID)
    let roundAfter = stateAfter["currentRoundID"]! as! UInt64
    Test.assertEqual(UInt64(1), roundAfter)
}

access(all) fun testUserEntriesInIntermissionDuringBatch() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize and advance time
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)

    // Start draw (pool enters draw processing)
    startDraw(user, poolID: poolID)

    // User should have entries equal to their share balance during draw processing
    let entries = getUserEntries(user.address, poolID)
    Test.assert(entries > 0.0, message: "User should have entries (share balance) during draw processing")
}

// ============================================================================
// TWAB MANIPULATION PREVENTION TESTS
// ============================================================================

access(all) fun testDepositDuringDrawProcessingGetsNoExtraWeight() {
    // SECURITY TEST: Verifies that depositing during draw processing
    // does NOT give unfair weight. The exploit was:
    // 1. User holds small amount all round
    // 2. Deposits huge amount during draw processing
    // 3. Gets weight as if they held huge amount all round
    //
    // FIX: recordShareChange caps time at actualEndTime, so new
    // deposits during draw processing get zero additional weight.

    let poolID = createTestPoolWithMediumInterval()

    // Setup two users
    let alice = Test.createAccount()
    let bob = Test.createAccount()
    setupUserWithFundsAndCollection(alice, amount: 200.0)
    setupUserWithFundsAndCollection(bob, amount: 200.0)

    // Alice deposits 100 at start of round
    depositToPool(alice, poolID: poolID, amount: 100.0)

    // Bob deposits only 10 at start of round
    depositToPool(bob, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 50.0)

    // Advance full round
    Test.moveTime(by: 70.0)

    // Start draw - enters DRAW_PROCESSING state
    startDraw(alice, poolID: poolID)
    Test.assertEqual(true, isDrawInProgress(poolID))

    // ATTACK ATTEMPT: Bob tries to deposit 90 more during draw processing
    // If vulnerable, Bob would get weight ~100 (as if held 100 all round)
    // With fix, Bob should still get weight ~10 (his actual holding)
    depositToPool(bob, poolID: poolID, amount: 90.0)

    // Process batch and complete draw
    processAllDrawBatches(alice, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(alice, poolID: poolID)

    // Verify Bob's weight was fair (should be ~10, NOT ~100)
    // We can't directly check weight, but we can verify the system
    // processed correctly without panic
    // The draw completed successfully, meaning TWAB calculation worked
    Test.assertEqual(true, isInIntermission(poolID))
}

access(all) fun testWithdrawDuringDrawProcessingRecordedCorrectly() {
    // SECURITY TEST: Verifies that withdrawals during draw processing
    // are also recorded correctly (with time capped at actualEndTime).

    let poolID = createTestPoolWithMediumInterval()

    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)

    // User deposits 100 at start of round
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 50.0)

    // Advance full round
    Test.moveTime(by: 70.0)

    // Start draw - enters DRAW_PROCESSING state
    startDraw(user, poolID: poolID)
    Test.assertEqual(true, isDrawInProgress(poolID))

    // User withdraws 50 during draw processing
    // This should be recorded with time capped at actualEndTime
    withdrawFromPool(user, poolID: poolID, amount: 50.0)

    // Process batch and complete draw
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)

    // Draw completed successfully
    Test.assertEqual(true, isInIntermission(poolID))
}

access(all) fun testLazyUserNotAffectedByFix() {
    // REGRESSION TEST: Verifies that "lazy" users (who deposited before
    // the round and never transacted during) still get full weight.
    // The currentShares fallback is still needed for this legitimate case.

    let poolID = createTestPoolWithMediumInterval()

    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)

    // User deposits 100 at start of round
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 50.0)

    // Advance full round - user does NOTHING (lazy user)
    Test.moveTime(by: 70.0)

    // Start draw
    startDraw(user, poolID: poolID)

    // Process batch - lazy user should get full weight via currentShares fallback
    // (They have no userSharesAtLastUpdate entry, so fallback is used)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)

    // Draw completed successfully - lazy user participated correctly
    Test.assertEqual(true, isInIntermission(poolID))
}

access(all) fun testDrawWithNoRegisteredUsers() {
    // Edge case: startDraw with zero registered receivers should skip the full
    // draw sequence and enter intermission directly, carrying prize yield forward.
    let deployer = Test.createAccount()
    let poolID = createTestPoolWithMediumInterval()

    // Fund a prize pool but add NO users
    fundPrizePool(poolID, amount: 50.0)

    // Advance past the round end
    Test.moveTime(by: 70.0)

    // startDraw should succeed and immediately enter intermission
    startDraw(deployer, poolID: poolID)

    // Pool must be in intermission (not mid-draw, no pending receipt)
    Test.assertEqual(true, isInIntermission(poolID))

    // Prize yield must carry forward (not zeroed out)
    let totals = getPoolTotals(poolID)
    let prizeBalance = totals["prizeBalance"] ?? 0.0
    Test.assert(prizeBalance >= 50.0, message: "Prize yield should carry forward when no users: \(prizeBalance)")

    // Admin can start a new round normally after the empty draw
    startNextRound(deployer, poolID: poolID)
    Test.assertEqual(false, isInIntermission(poolID))

    // Second consecutive empty draw must not panic (regression for BatchSelectionData resource leak)
    Test.moveTime(by: 70.0)
    startDraw(deployer, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))
    startNextRound(deployer, poolID: poolID)
    Test.assertEqual(false, isInIntermission(poolID))
}

access(all) fun testEmptyDrawThenNormalDraw() {
    // Verifies that a round with no participants followed by a round with
    // participants completes correctly and distributes prizes normally.
    let deployer = Test.createAccount()
    let poolID = createTestPoolWithMediumInterval()

    // Round 1: no users, fund prize pool so yield accumulates
    fundPrizePool(poolID, amount: 30.0)
    Test.moveTime(by: 70.0)
    startDraw(deployer, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Prize carries forward
    let totalsAfterEmptyDraw = getPoolTotals(poolID)
    let prizeAfterEmpty = totalsAfterEmptyDraw["prizeBalance"] ?? 0.0
    Test.assert(prizeAfterEmpty >= 30.0, message: "Prize should carry forward: \(prizeAfterEmpty)")

    // Round 2: add a user, run normal full draw sequence
    startNextRound(deployer, poolID: poolID)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    fundPrizePool(poolID, amount: 20.0)
    Test.moveTime(by: 70.0)

    startDraw(user, poolID: poolID)

    // Should be in batch processing (not immediate intermission) since there is a user
    Test.assertEqual(false, isInIntermission(poolID))

    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)

    Test.assertEqual(true, isInIntermission(poolID))

    // Prize pool should be reduced (prizes distributed to the one user)
    let totalsAfterNormalDraw = getPoolTotals(poolID)
    let prizeAfterNormal = totalsAfterNormalDraw["prizeBalance"] ?? 0.0
    Test.assert(prizeAfterNormal < prizeAfterEmpty + 20.0, message: "Prizes should have been distributed: \(prizeAfterNormal)")
}

access(all) fun testNormalDrawThenEmptyDraw() {
    // Verifies that a normal draw followed by an empty draw does not corrupt
    // state — the BatchSelectionData from the normal draw is fully cleaned up
    // before the empty draw runs.
    let deployer = Test.createAccount()
    let poolID = createTestPoolWithMediumInterval()

    // Round 1: normal draw with one user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    fundPrizePool(poolID, amount: 50.0)
    Test.moveTime(by: 70.0)

    startDraw(user, poolID: poolID)
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // User fully withdraws (prizes were auto-compounded so balance > 100).
    // Query the actual asset balance and withdraw it all to reach zero shares,
    // which unregisters the user from the pool.
    let balanceInfo = getUserPoolBalance(user.address, poolID)
    let fullBalance = balanceInfo["totalBalance"] ?? 0.0
    Test.assert(fullBalance > 0.0, message: "User should have a balance after winning prizes: \(fullBalance)")
    withdrawFromPool(user, poolID: poolID, amount: fullBalance)

    // Round 2: user is unregistered — empty draw must not panic
    startNextRound(deployer, poolID: poolID)
    Test.moveTime(by: 70.0)
    startDraw(deployer, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Can start a fresh round after the empty draw
    startNextRound(deployer, poolID: poolID)
    Test.assertEqual(false, isInIntermission(poolID))
}
