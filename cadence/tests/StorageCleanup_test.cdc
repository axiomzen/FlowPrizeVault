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
// TESTS - Basic Cleanup Functionality
// ============================================================================

access(all) fun testCleanupWithNoStaleEntries() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant with active deposit
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Get initial receiver count
    let initialReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(1, initialReceiverCount)
    
    // Run cleanup - should not affect active users
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    // Verify receiver count unchanged
    let finalReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(1, finalReceiverCount)
    
    // Verify user still has balance via entries (which uses shares)
    let entries = getUserEntries(participant.address, poolID)
    Test.assert(entries > 0.0, message: "User should still have entries")
}

access(all) fun testCleanupGhostReceiverAfterFullWithdrawal() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Verify registered
    let initialReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(1, initialReceiverCount)
    
    // Full withdrawal (outside of draw) should auto-unregister
    withdrawFromPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Should already be unregistered (no draw in progress)
    let afterWithdrawCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(0, afterWithdrawCount)
    
    // Cleanup should have nothing to do for receivers (but may clean dict entries)
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    let finalReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(0, finalReceiverCount)
}

access(all) fun testCleanupGhostReceiverCreatedDuringDraw() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup two participants
    let participant1 = Test.createAccount()
    let participant2 = Test.createAccount()
    setupUserWithFundsAndCollection(participant1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Verify initial state
    let initialReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(2, initialReceiverCount)
    
    // Start draw - this creates pendingSelectionData
    startDraw(participant1, poolID: poolID)
    
    // Verify draw is in progress
    let drawStatus = getDrawStatus(poolID)
    let isBatchInProgress = drawStatus["isBatchInProgress"]! as! Bool
    Test.assert(isBatchInProgress, message: "Draw should be in progress")
    
    // participant1 withdraws fully DURING draw
    // This creates a "ghost" receiver (0 shares but still in list)
    withdrawFromPool(participant1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Ghost should still be in the list (can't unregister during draw)
    let duringDrawCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(2, duringDrawCount)
    
    // Complete the draw
    processAllDrawBatches(participant1, poolID: poolID, batchSize: 10)
    requestDrawRandomness(participant1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(participant1, poolID: poolID)
    
    // After draw, one of them might have won the prize (gets new shares)
    // So we may have 1 ghost + 1 winner, or 2 if no prize awarded
    let afterDrawCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(2, afterDrawCount)
    
    // Now run cleanup - should remove any ghosts (those with 0 shares)
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    // Should have at least 1 remaining (winner or participant2)
    // Could be 1 (participant2 only, participant1 ghost cleaned)
    // Could be 2 (both have shares if prize awarded to participant1)
    let finalReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assert(finalReceiverCount >= 1, message: "At least one receiver should remain")
    Test.assert(finalReceiverCount <= 2, message: "At most 2 receivers should remain")
}

// ============================================================================
// TESTS - Cleanup Blocked During Active Draw
// ============================================================================

access(all) fun testCleanupBlockedDuringBatchProcessing() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(participant, poolID: poolID)
    
    // Try to run cleanup during draw - should fail
    let result = cleanupPoolStaleEntriesExpectFailure(poolID, receiverLimit: 100)
    Test.expect(result, Test.beFailed())
}

access(all) fun testCleanupBlockedAfterRandomnessRequested() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw and request randomness
    startDraw(participant, poolID: poolID)
    processAllDrawBatches(participant, poolID: poolID, batchSize: 10)
    requestDrawRandomness(participant, poolID: poolID)
    
    // Try to run cleanup - should fail (pendingSelectionData still exists)
    let result = cleanupPoolStaleEntriesExpectFailure(poolID, receiverLimit: 100)
    Test.expect(result, Test.beFailed())
    
    // Complete the draw
    commitBlocksForRandomness()
    completeDraw(participant, poolID: poolID)
    
    // Now cleanup should work
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
}

// ============================================================================
// TESTS - Cleanup Without Draw (simpler scenario)
// ============================================================================

access(all) fun testCleanupWorksOnMultipleGhostsWithoutDraw() {
    // This test avoids the complexity of prize distribution
    // by creating ghosts without running a draw
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 3 participants
    let p1 = Test.createAccount()
    let p2 = Test.createAccount()
    let p3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(p1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(p2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(p3, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(p1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(p2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(p3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Verify all registered
    let initialCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(3, initialCount)
    
    // Withdraw all WITHOUT a draw in progress
    // They should be auto-unregistered immediately
    withdrawFromPool(p1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    withdrawFromPool(p2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    withdrawFromPool(p3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // All should be unregistered immediately (no ghosts created)
    let afterWithdrawCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(0, afterWithdrawCount)
    
    // Cleanup has no receivers to clean, but may clean dict entries
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    let finalCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(0, finalCount)
}

// ============================================================================
// TESTS - Multiple User Scenarios
// ============================================================================

access(all) fun testCleanupDoesNotAffectActiveUsers() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 3 participants
    let active1 = Test.createAccount()
    let active2 = Test.createAccount()
    let withdrawer = Test.createAccount()
    
    setupUserWithFundsAndCollection(active1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(active2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(withdrawer, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(active1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(active2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(withdrawer, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(active1, poolID: poolID)
    
    // Only withdrawer exits during draw
    withdrawFromPool(withdrawer, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Complete draw
    processAllDrawBatches(active1, poolID: poolID, batchSize: 10)
    requestDrawRandomness(active1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(active1, poolID: poolID)
    
    // Run cleanup
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    // Should have at least 2 active users remaining (may have 3 if withdrawer won)
    let finalCount = getRegisteredReceiverCount(poolID)
    Test.assert(finalCount >= 2, message: "At least 2 active users should remain")
    
    // Verify active users still have entries (share-based)
    let entries1 = getUserEntries(active1.address, poolID)
    let entries2 = getUserEntries(active2.address, poolID)
    Test.assert(entries1 > 0.0, message: "Active user 1 should have entries")
    Test.assert(entries2 > 0.0, message: "Active user 2 should have entries")
}

access(all) fun testCleanupAfterUserRedeposits() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 2.0 + 2.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(participant, poolID: poolID)
    
    // Withdraw fully during draw (becomes ghost)
    withdrawFromPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Re-deposit during same draw (should still be registered, now with balance again)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Complete draw
    processAllDrawBatches(participant, poolID: poolID, batchSize: 10)
    requestDrawRandomness(participant, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(participant, poolID: poolID)
    
    // Run cleanup - should NOT remove this user (they have balance now)
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    
    // User should still be registered
    let finalCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(1, finalCount)
    
    // Verify user has entries (share-based)
    let entries = getUserEntries(participant.address, poolID)
    Test.assert(entries > 0.0, message: "User should have entries after re-deposit")
}

// ============================================================================
// TESTS - Cleanup Consistency
// ============================================================================

access(all) fun testMultipleCleanupCallsAreIdempotent() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant who will become a ghost
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Create ghost during draw
    startDraw(participant, poolID: poolID)
    withdrawFromPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    processAllDrawBatches(participant, poolID: poolID, batchSize: 10)
    requestDrawRandomness(participant, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(participant, poolID: poolID)
    
    // After draw, participant might have won and have shares again
    // Get current count before cleanup
    let beforeCleanup = getRegisteredReceiverCount(poolID)
    
    // First cleanup
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    let afterFirst = getRegisteredReceiverCount(poolID)
    
    // Second cleanup - should be idempotent (no change)
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    let afterSecond = getRegisteredReceiverCount(poolID)
    Test.assertEqual(afterFirst, afterSecond)
    
    // Third cleanup - still idempotent
    cleanupPoolStaleEntries(poolID, receiverLimit: 100)
    let afterThird = getRegisteredReceiverCount(poolID)
    Test.assertEqual(afterFirst, afterThird)
}

// ============================================================================
// TESTS - Receiver Limit Behavior
// ============================================================================

access(all) fun testReceiverLimitOfOne() {
    // Test with minimal limit to verify batching works
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup 2 participants
    let p1 = Test.createAccount()
    let p2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(p1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(p2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(p1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(p2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    
    // Start draw
    startDraw(p1, poolID: poolID)
    
    // Both withdraw during draw
    withdrawFromPool(p1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    withdrawFromPool(p2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Complete draw
    processAllDrawBatches(p1, poolID: poolID, batchSize: 10)
    requestDrawRandomness(p1, poolID: poolID)
    commitBlocksForRandomness()
    completeDraw(p1, poolID: poolID)
    
    // Get count after draw (before cleanup)
    let afterDraw = getRegisteredReceiverCount(poolID)
    Test.assertEqual(2, afterDraw)
    
    // Cleanup with limit=1
    cleanupPoolStaleEntries(poolID, receiverLimit: 1)
    
    // Should still have at least 1 remaining (either 1 ghost + 0 active, or 1 active after winning)
    let afterFirstCleanup = getRegisteredReceiverCount(poolID)
    Test.assert(afterFirstCleanup >= 1, message: "Should have receivers after partial cleanup")
    
    // Another cleanup
    cleanupPoolStaleEntries(poolID, receiverLimit: 1)
    
    // Continue until stable
    cleanupPoolStaleEntries(poolID, receiverLimit: 10)
    
    let finalCount = getRegisteredReceiverCount(poolID)
    // Final count depends on whether someone won the prize
    Test.assert(finalCount <= 1, message: "Should have at most 1 receiver (winner or none)")
}
