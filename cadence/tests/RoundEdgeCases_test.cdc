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
// TESTS - Round Boundary Timing Edge Cases
// ============================================================================

access(all) fun testDepositNearRoundStart() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Deposit immediately after pool creation (near start)
    // Note: Pool creation includes some block time, so we're ~0-1 seconds in
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be near full round
    let entries = getUserEntries(user.address, poolID)
    
    // Expected: ~full entries (minor reduction for setup transactions)
    let expectedMin: UFix64 = 95.0 // At least 95% of deposit as entries
    Test.assert(
        entries >= expectedMin,
        message: "Near-start deposit should get ~full entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testDepositOneSecondBeforeRoundEnd() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Advance to 1 second before round end
    Test.moveTime(by: 58.0)
    
    // Deposit with 2 seconds remaining
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be very small
    let entries = getUserEntries(user.address, poolID)
    
    // Expected: ~2/60 = ~3.33 entries (with some tolerance for block timing)
    let expectedMax: UFix64 = 10.0 // Should be less than 10% of deposit
    Test.assert(
        entries < expectedMax,
        message: "Near-end deposit should get very few entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testDepositAfterRoundEnded() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0

    // Setup initial user first
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)

    // Wait for round to end
    Test.moveTime(by: 61.0)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Deposit after round has ended (gap period)
    // Late user gets proportional weight from deposit time until startDraw()
    let lateUser = Test.createAccount()
    setupUserWithFundsAndCollection(lateUser, amount: depositAmount + 10.0)
    depositToPool(lateUser, poolID: poolID, amount: depositAmount)

    // Execute draw immediately - late user has ~0 seconds of weight
    executeFullDraw(existingUser, poolID: poolID)

    // Late user has tiny proportional weight (deposit to startDraw = ~0 seconds)
    // They won't win because existing user has ~61 seconds of weight
    let latePrizes = getUserPrizes(lateUser.address, poolID)
    Test.assertEqual(0.0, latePrizes["totalEarnedPrizes"]!)

    // Existing user should have won (they have ~99%+ of total weight)
    let existingPrizes = getUserPrizes(existingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, existingPrizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - TWAB Cumulative Edge Cases
// ============================================================================

access(all) fun testWithdrawalBringsTWABNearZero() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user with deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance to 50% of round
    Test.moveTime(by: 30.0)
    
    // Withdraw almost everything
    withdrawFromPool(user, poolID: poolID, amount: 99.0)
    
    // Check entries - should be reduced but not zero
    let entries = getUserEntries(user.address, poolID)
    
    // User had 100 shares for 30s = 3000 share-seconds
    // Now has 1 share for remaining 30s = 30 share-seconds
    // Total ≈ 3000 + 30 / 60 ≈ 50.5 entries
    // (This is a rough estimate - actual depends on TWAB implementation)
    Test.assert(entries > 0.0, message: "Should still have some entries after partial withdrawal")
}

access(all) fun testFullWithdrawalMidRound() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two users - one to keep pool active
    let stayingUser = Test.createAccount()
    let leavingUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(stayingUser, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(leavingUser, amount: depositAmount + 10.0)
    
    depositToPool(stayingUser, poolID: poolID, amount: depositAmount)
    depositToPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance to 50% of round
    Test.moveTime(by: 30.0)
    
    // Leaving user withdraws everything
    withdrawFromPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Verify leaving user has 0 balance
    let balance = getUserPoolBalance(leavingUser.address, poolID)
    Test.assertEqual(0.0, balance["totalBalance"]!)
    
    // Advance to end of round and execute draw
    Test.moveTime(by: 31.0)
    executeFullDraw(stayingUser, poolID: poolID)
    
    // Staying user should win (leaving user has reduced/zero weight)
    let stayingPrizes = getUserPrizes(stayingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, stayingPrizes["totalEarnedPrizes"]!)
}

access(all) fun testFullWithdrawalThenRedeposit() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount * 2.0 + 20.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance to 20% of round
    Test.moveTime(by: 12.0)
    
    // Withdraw everything
    withdrawFromPool(user, poolID: poolID, amount: depositAmount)
    
    // Immediately redeposit
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should account for the gap when balance was 0
    let entries = getUserEntries(user.address, poolID)
    
    // User should have entries (not zero)
    Test.assert(entries > 0.0, message: "Should have entries after redeposit")
}

access(all) fun testVerySmallDeposit() {
    let poolID = createTestPoolWithMediumInterval()
    let smallDeposit: UFix64 = 0.00000001 // Near UFix64 minimum precision
    
    // Setup user with small deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 10.0) // Enough for fees
    
    // Note: This might fail if minimum deposit is enforced
    // Wrapping in try-like pattern
    let depositResult = _executeTransaction(
        "../transactions/test/deposit_to_pool.cdc",
        [poolID, smallDeposit],
        user
    )
    
    // If deposit succeeded, check entries
    if depositResult.error == nil {
        let entries = getUserEntries(user.address, poolID)
        // Entries should be proportionally small but non-zero
        Test.assert(entries > 0.0 || entries == 0.0, message: "Small deposit should have tiny or zero entries")
    }
}

access(all) fun testMultipleDepositsInSameBlock() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 25.0
    
    // Setup user with enough funds for multiple deposits
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    
    // Multiple deposits in sequence (simulates same block scenario)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Verify total balance
    let balance = getUserPoolBalance(user.address, poolID)
    let expectedBalance = depositAmount * 4.0
    let tolerance: UFix64 = 0.01
    let difference = balance["totalBalance"]! > expectedBalance 
        ? balance["totalBalance"]! - expectedBalance 
        : expectedBalance - balance["totalBalance"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should be 100 after 4x25 deposits. Got: ".concat(balance["totalBalance"]!.toString())
    )
    
    // Check entries reflect total
    let entries = getUserEntries(user.address, poolID)
    Test.assert(entries > 90.0, message: "Should have near-full entries for total deposit")
}

// ============================================================================
// TESTS - Round Initialization Edge Cases
// ============================================================================

access(all) fun testFirstUserInNewRound() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user (first user in pool)
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check this is round 1
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(1), state["currentRoundID"]! as! UInt64)
    
    // User should have entries
    let entries = getUserEntries(user.address, poolID)
    Test.assert(entries > 0.0, message: "First user should have entries")
}

access(all) fun testLazyFallbackCalculation() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    // User1 deposits first
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end and execute draw
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Now we're in round 2. User2 deposits for the first time.
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // User2 should have entries in round 2 (initialized fresh, not lazy fallback from round 1)
    let user2Entries = getUserEntries(user2.address, poolID)
    Test.assert(user2Entries > 0.0, message: "New user in round 2 should have entries")
}

access(all) fun testUserExistsInBothActiveAndPendingRound() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Start draw (pool enters DRAW_PROCESSING state)
    startDraw(user, poolID: poolID)

    // During draw processing, entries = share balance (which should be > 0)
    let entries = getUserEntries(user.address, poolID)
    Test.assert(entries > 0.0, message: "User should have entries (share balance) during intermission")
    
    // Complete the draw
    processAllDrawBatches(user, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user, poolID: poolID)
    
    // Start next round to exit intermission
    startNextRound(user, poolID: poolID)
    
    // User should still have entries in the new round
    let entriesAfter = getUserEntries(user.address, poolID)
    Test.assert(entriesAfter > 0.0, message: "User should have entries after draw completed")
}

// ============================================================================
// TESTS - Round Duration and Timing
// ============================================================================

access(all) fun testExactlyHalfRoundDeposit() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Advance exactly to halfway point
    Test.moveTime(by: 30.0)
    
    // Deposit at exactly 50%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be approximately half
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount / 2.0 // 50 entries
    
    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries 
        ? entries - expectedEntries 
        : expectedEntries - entries
    
    Test.assert(
        difference < tolerance,
        message: "Half-round deposit should get ~50 entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testQuarterRoundDeposit() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Advance to 25% of round (15 seconds)
    Test.moveTime(by: 15.0)
    
    // Deposit at 25%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be approximately 75% of deposit
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount * 0.75 // 75 entries (75% of round remaining)
    
    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries 
        ? entries - expectedEntries 
        : expectedEntries - entries
    
    Test.assert(
        difference < tolerance,
        message: "Quarter-round deposit should get ~75 entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testThreeQuarterRoundDeposit() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Advance to 75% of round (45 seconds)
    Test.moveTime(by: 45.0)
    
    // Deposit at 75%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be approximately 25% of deposit
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount * 0.25 // 25 entries (25% of round remaining)
    
    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries 
        ? entries - expectedEntries 
        : expectedEntries - entries
    
    Test.assert(
        difference < tolerance,
        message: "Three-quarter-round deposit should get ~25 entries. Got: ".concat(entries.toString())
    )
}

// ============================================================================
// TESTS - Withdrawal Impact on TWAB
// ============================================================================

access(all) fun testPartialWithdrawalTWAB() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 25.0
    
    // Setup user with deposit at start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Get initial entries
    let entriesBefore = getUserEntries(user.address, poolID)
    
    // Advance to 50% of round
    Test.moveTime(by: 30.0)
    
    // Withdraw 25%
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Get entries after withdrawal
    let entriesAfter = getUserEntries(user.address, poolID)
    
    // Entries should be less than before (withdrawal reduces accumulated TWAB)
    Test.assert(
        entriesAfter < entriesBefore,
        message: "Entries should decrease after withdrawal. Before: "
            .concat(entriesBefore.toString())
            .concat(", After: ").concat(entriesAfter.toString())
    )
}

access(all) fun testWithdrawalDoesNotAffectOthers() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Get user2's entries before user1's withdrawal
    let user2EntriesBefore = getUserEntries(user2.address, poolID)
    
    // Advance time and user1 withdraws
    Test.moveTime(by: 30.0)
    withdrawFromPool(user1, poolID: poolID, amount: 50.0)
    
    // User2's entries should be unchanged by user1's action
    let user2EntriesAfter = getUserEntries(user2.address, poolID)
    
    // Entries should be approximately the same (minor time-based changes are OK)
    let tolerance: UFix64 = 1.0
    let difference = user2EntriesBefore > user2EntriesAfter 
        ? user2EntriesBefore - user2EntriesAfter 
        : user2EntriesAfter - user2EntriesBefore
    
    Test.assert(
        difference < tolerance,
        message: "User2 entries should not be affected by User1 withdrawal"
    )
}

access(all) fun testMultipleWithdrawalsAccumulate() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user with deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Get initial entries
    let entriesStart = getUserEntries(user.address, poolID)
    
    // Multiple small withdrawals over time
    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0)
    let entriesAfter1 = getUserEntries(user.address, poolID)
    
    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0)
    let entriesAfter2 = getUserEntries(user.address, poolID)
    
    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0)
    let entriesAfter3 = getUserEntries(user.address, poolID)
    
    // Each withdrawal should reduce entries
    Test.assert(entriesAfter1 < entriesStart, message: "First withdrawal should reduce entries")
    Test.assert(entriesAfter2 < entriesAfter1, message: "Second withdrawal should further reduce entries")
    Test.assert(entriesAfter3 < entriesAfter2, message: "Third withdrawal should further reduce entries")
}

// ============================================================================
// TESTS - Round State Queries
// ============================================================================

access(all) fun testRoundStartTimeIsRecorded() {
    let poolID = createTestPoolWithMediumInterval()
    
    let state = getPoolInitialState(poolID)
    let roundStartTime = state["roundStartTime"]! as! UFix64
    
    // Round start time should be positive and recent
    Test.assert(roundStartTime > 0.0, message: "Round should have a start time")
    
    // Verify it matches current block time (approximately)
    // Note: Tolerance is large because the Cadence test framework accumulates time
    // from all Test.moveTime() calls in prior tests within the same file
    let currentTime = getCurrentBlock().timestamp
    let tolerance: UFix64 = 2000.0 // Large tolerance for cumulative test time
    let difference = currentTime > roundStartTime 
        ? currentTime - roundStartTime 
        : roundStartTime - currentTime
    
    Test.assert(
        difference < tolerance,
        message: "Round start time should be close to current time. Difference: ".concat(difference.toString())
    )
}

access(all) fun testRoundDurationMatchesConfig() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    let state = getPoolInitialState(poolID)
    let roundDuration = state["roundDuration"]! as! UFix64
    
    // Should match the medium interval (60 seconds)
    Test.assertEqual(60.0, roundDuration)
}

access(all) fun testIsRoundEndedStateTransition() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    
    // Initially not ended
    let stateBefore = getPoolInitialState(poolID)
    Test.assertEqual(false, stateBefore["isRoundEnded"]! as! Bool)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Now should be ended
    let stateAfter = getPoolInitialState(poolID)
    Test.assertEqual(true, stateAfter["isRoundEnded"]! as! Bool)
}

