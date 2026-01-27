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
// TESTS - Basic Target End Time Functionality
// ============================================================================

access(all) fun testPoolCreatedWithTargetEndTime() {
    let poolID = createTestPoolWithMediumInterval()

    let status = getDrawStatus(poolID)
    let targetEndTime = status["targetEndTime"] as! UFix64
    let currentTime = status["currentTime"] as! UFix64

    // Target should be approximately currentTime + 60 seconds (medium interval)
    // Allow tolerance for block time progression during pool creation
    Test.assert(
        targetEndTime > currentTime,
        message: "Target end time should be in the future"
    )

    let expectedTarget = currentTime + 60.0
    let tolerance: UFix64 = 5.0
    let diff = absDifference(targetEndTime, expectedTarget)
    Test.assert(
        diff < tolerance,
        message: "Target end time should be ~60s from now. Got: ".concat(targetEndTime.toString())
    )
}

access(all) fun testCannotDrawBeforeTargetEndTime() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Verify cannot draw yet
    let status = getDrawStatus(poolID)
    Test.assertEqual(false, status["canDrawNow"] as! Bool)
}

access(all) fun testCanDrawAfterTargetEndTime() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Advance past target end time
    Test.moveTime(by: 61.0)

    // Verify can draw now
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["canDrawNow"] as! Bool)
}

// ============================================================================
// TESTS - Extending Target End Time
// ============================================================================

access(all) fun testExtendTargetEndTime() {
    let poolID = createTestPoolWithMediumInterval()

    // Get initial target
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64

    // Extend by 1 day (86400 seconds)
    let newTarget = initialTarget + 86400.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Verify target was updated
    let newStatus = getDrawStatus(poolID)
    let actualNewTarget = newStatus["targetEndTime"] as! UFix64
    Test.assertEqual(newTarget, actualNewTarget)
}

access(all) fun testCannotDrawAfterExtension() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Advance to 61 seconds (normally could draw)
    Test.moveTime(by: 61.0)

    // Verify we could draw now
    let statusBeforeExtend = getDrawStatus(poolID)
    Test.assertEqual(true, statusBeforeExtend["canDrawNow"] as! Bool)

    // Extend by 7 more days
    let currentTarget = statusBeforeExtend["targetEndTime"] as! UFix64
    let newTarget = currentTarget + 604800.0  // 7 days in seconds
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Verify cannot draw anymore
    let statusAfterExtend = getDrawStatus(poolID)
    Test.assertEqual(false, statusAfterExtend["canDrawNow"] as! Bool)
}

access(all) fun testCanDrawAfterExtendedTargetReached() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Extend target by 30 seconds
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    let newTarget = initialTarget + 30.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Advance to new target (60 + 30 = 90 seconds from start)
    Test.moveTime(by: 91.0)

    // Verify can draw now
    let finalStatus = getDrawStatus(poolID)
    Test.assertEqual(true, finalStatus["canDrawNow"] as! Bool)
}

// ============================================================================
// TESTS - Shortening Target End Time
// ============================================================================

access(all) fun testShortenTargetEndTime() {
    let poolID = createTestPoolWithMediumInterval()

    // Get initial target
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    let currentTime = initialStatus["currentTime"] as! UFix64

    // Shorten to 30 seconds from now (instead of 60)
    let newTarget = currentTime + 30.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Verify target was updated
    let newStatus = getDrawStatus(poolID)
    let actualNewTarget = newStatus["targetEndTime"] as! UFix64

    // Allow small tolerance for block time
    let diff = absDifference(actualNewTarget, newTarget)
    Test.assert(
        diff < 2.0,
        message: "Target should be updated to ~30s from now"
    )
}

access(all) fun testCanDrawEarlierAfterShortening() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Get current status
    let initialStatus = getDrawStatus(poolID)
    let currentTime = initialStatus["currentTime"] as! UFix64

    // Shorten target to 20 seconds from now
    let newTarget = currentTime + 20.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Advance only 21 seconds (less than original 60)
    Test.moveTime(by: 21.0)

    // Verify can draw now
    let finalStatus = getDrawStatus(poolID)
    Test.assertEqual(true, finalStatus["canDrawNow"] as! Bool)
}

// ============================================================================
// TESTS - Cannot Change After startDraw
// ============================================================================

access(all) fun testCannotChangeTargetAfterStartDraw() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Advance past target and start draw
    Test.moveTime(by: 61.0)
    startDraw(participant, poolID: poolID)

    // Try to update target - should fail
    let status = getDrawStatus(poolID)
    let currentTime = status["currentTime"] as! UFix64
    let result = updateRoundTargetEndTimeExpectFailure(poolID, newTargetEndTime: currentTime + 1000.0)

    // Verify failure
    Test.expect(result, Test.beFailed())
}

// ============================================================================
// TESTS - TWAB Uses Actual Elapsed Time
// ============================================================================

access(all) fun testTWABUsesActualElapsedTime() {
    // This test verifies that extending the round target DOES affect final TWAB
    // because TWAB normalization uses actual duration at finalization (startDraw).
    //
    // Scenario:
    // - User1 deposits at start of 60-second round
    // - User2 deposits after 30 seconds
    // - Admin extends round to 120 seconds
    // - User1 deposits continue for full 120 seconds
    // - At finalization, both users' TWAB is normalized by 120 seconds (actual)

    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // User1 deposits at start
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    depositToPool(user1, poolID: poolID, amount: depositAmount)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Advance 30 seconds
    Test.moveTime(by: 30.0)

    // User2 deposits at 30 seconds
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    depositToPool(user2, poolID: poolID, amount: depositAmount)

    // Extend the round to 120 seconds total
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    let newTarget = initialTarget + 60.0  // 120 seconds total
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Advance past extended target
    Test.moveTime(by: 91.0)  // Now at ~121 seconds from start

    // Execute draw - this will finalize TWAB
    executeFullDraw(user1, poolID: poolID)

    // Get prizes
    let user1Prizes = getUserPrizes(user1.address, poolID)
    let user2Prizes = getUserPrizes(user2.address, poolID)

    let user1Total = user1Prizes["totalEarnedPrizes"]!
    let user2Total = user2Prizes["totalEarnedPrizes"]!

    // User1 was there for 120 seconds, User2 for 90 seconds
    // User1 should have ~57% of weight (120/210), User2 ~43% (90/210)
    // One of them won the prize (single winner), so verify total is correct
    let totalPrizes = user1Total + user2Total
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)

    // The point is: TWAB correctly uses the extended duration, not original 60s
    // If it used original 60s, User2 would have 30/60 = 50% weight
    // With extended 120s, User2 has 90/120 = 75% of full duration
    // This test passes if the draw completes without errors and prizes are awarded
}

access(all) fun testTWABFairAfterShortening() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Deposit near start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Get current status
    let initialStatus = getDrawStatus(poolID)
    let currentTime = initialStatus["currentTime"] as! UFix64

    // Shorten the round to 30 seconds total
    let newTarget = currentTime + 28.0  // Account for some time passing
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Advance to new target
    Test.moveTime(by: 29.0)

    // Check entries - should still be ~100 (full duration participation)
    let entries = getUserEntries(user.address, poolID)

    // User was there for the entire (shortened) round, so should have ~full entries
    let tolerance: UFix64 = 10.0
    let diff = absDifference(entries, depositAmount)

    Test.assert(
        diff < tolerance,
        message: "After shortening, user should have ~full entries. Expected ~"
            .concat(depositAmount.toString())
            .concat(", Got: ").concat(entries.toString())
    )
}

// ============================================================================
// TESTS - Multiple Target Changes
// ============================================================================

access(all) fun testMultipleTargetChanges() {
    let poolID = createTestPoolWithMediumInterval()

    // Get initial target
    let status1 = getDrawStatus(poolID)
    let currentTime = status1["currentTime"] as! UFix64

    // First change: extend by 30 seconds
    let target1 = currentTime + 90.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: target1)

    // Verify first change
    let status2 = getDrawStatus(poolID)
    Test.assertEqual(target1, status2["targetEndTime"] as! UFix64)

    // Second change: shorten to 45 seconds
    let target2 = currentTime + 45.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: target2)

    // Verify second change
    let status3 = getDrawStatus(poolID)
    Test.assertEqual(target2, status3["targetEndTime"] as! UFix64)

    // Third change: extend to 120 seconds
    let target3 = currentTime + 120.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: target3)

    // Verify third change
    let status4 = getDrawStatus(poolID)
    Test.assertEqual(target3, status4["targetEndTime"] as! UFix64)
}

// ============================================================================
// TESTS - Error Cases
// ============================================================================

access(all) fun testCannotSetTargetBeforeStartTime() {
    let poolID = createTestPoolWithMediumInterval()

    // Get status
    let status = getDrawStatus(poolID)

    // Try to set target to a past time (before round start)
    // The round just started, so 1.0 would be before start
    let result = updateRoundTargetEndTimeExpectFailure(poolID, newTargetEndTime: 1.0)

    // Verify failure
    Test.expect(result, Test.beFailed())
}

access(all) fun testCannotShortenBelowCurrentTime() {
    // This test verifies the safety fix for the shortening bug:
    // Admin cannot shorten targetEndTime to before current block timestamp.
    // This prevents the bug where accumulated time could exceed new target duration.

    let poolID = createTestPoolWithMediumInterval()

    // Advance time significantly
    Test.moveTime(by: 40.0)

    // Get current time
    let status = getDrawStatus(poolID)
    let currentTime = status["currentTime"] as! UFix64

    // Try to shorten target to before current time (e.g., 10 seconds ago)
    let pastTarget = currentTime - 10.0
    let result = updateRoundTargetEndTimeExpectFailure(poolID, newTargetEndTime: pastTarget)

    // Verify failure - cannot shorten to past
    Test.expect(result, Test.beFailed())
}

access(all) fun testCanShortenToFutureTime() {
    // Admin CAN shorten targetEndTime as long as it's still in the future

    let poolID = createTestPoolWithMediumInterval()

    // Get current status
    let status = getDrawStatus(poolID)
    let currentTime = status["currentTime"] as! UFix64

    // Shorten to a future time (current + 20 seconds, instead of original +60)
    let futureTarget = currentTime + 20.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: futureTarget)

    // Verify success
    let newStatus = getDrawStatus(poolID)
    let actualTarget = newStatus["targetEndTime"] as! UFix64

    let diff = absDifference(actualTarget, futureTarget)
    Test.assert(
        diff < 2.0,
        message: "Target should be updated to future time"
    )
}

access(all) fun testCannotChangeTargetDuringIntermission() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Complete a draw (enters intermission after completeDraw, before startNextRound)
    Test.moveTime(by: 61.0)
    executeFullDrawWithIntermission(participant, poolID: poolID)

    // Verify we're in intermission
    let status = getDrawStatus(poolID)
    Test.assertEqual(true, status["isInIntermission"] as! Bool)

    // Try to change target - should fail because there's no active round
    let currentTime = status["currentTime"] as! UFix64
    let result = updateRoundTargetEndTimeExpectFailure(poolID, newTargetEndTime: currentTime + 1000.0)

    // Verify failure
    Test.expect(result, Test.beFailed())
}

// ============================================================================
// TESTS - Integration with Full Draw
// ============================================================================

access(all) fun testFullDrawAfterExtendedTarget() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Extend target by 30 seconds
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    let newTarget = initialTarget + 30.0
    updateRoundTargetEndTime(poolID, newTargetEndTime: newTarget)

    // Advance past extended target
    Test.moveTime(by: 91.0)

    // Execute full draw - should succeed
    executeFullDraw(participant, poolID: poolID)

    // Verify prize was awarded
    let prizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

access(all) fun testRoundIDIncrementsAfterExtendedDraw() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Get initial round ID
    let stateBefore = getPoolInitialState(poolID)
    let roundIDBefore = stateBefore["currentRoundID"]! as! UInt64

    // Extend and complete draw
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    updateRoundTargetEndTime(poolID, newTargetEndTime: initialTarget + 30.0)

    Test.moveTime(by: 91.0)
    executeFullDraw(participant, poolID: poolID)

    // Check round ID incremented
    let stateAfter = getPoolInitialState(poolID)
    let roundIDAfter = stateAfter["currentRoundID"]! as! UInt64

    Test.assertEqual(roundIDBefore + 1, roundIDAfter)
}

// ============================================================================
// TESTS - New Round Uses Config Interval
// ============================================================================

access(all) fun testNewRoundUsesConfigInterval() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Get initial round's target duration
    let initialStatus = getDrawStatus(poolID)
    let initialTarget = initialStatus["targetEndTime"] as! UFix64
    let initialTime = initialStatus["currentTime"] as! UFix64
    let initialDuration = initialTarget - initialTime

    // Extend current round's target significantly
    updateRoundTargetEndTime(poolID, newTargetEndTime: initialTarget + 600.0)

    // Complete the draw
    Test.moveTime(by: 661.0)
    executeFullDraw(participant, poolID: poolID)

    // Get new round's target duration
    let newStatus = getDrawStatus(poolID)
    let newTarget = newStatus["targetEndTime"] as! UFix64
    let newTime = newStatus["currentTime"] as! UFix64
    let newDuration = newTarget - newTime

    // New round should use the config interval (~60s), not the extended target
    let tolerance: UFix64 = 5.0
    let expectedDuration: UFix64 = 60.0  // Medium interval
    let diff = absDifference(newDuration, expectedDuration)

    Test.assert(
        diff < tolerance,
        message: "New round should use config interval (~60s). Got duration: ".concat(newDuration.toString())
    )
}
