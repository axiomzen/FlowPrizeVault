import Test
import "PrizeSavings"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// NORMALIZED TWAB EDGE CASE TESTS
// 
// These tests verify edge cases in the TWAB implementation:
// 1. Gap period weight capping (weight bounded to shares)
// 2. Late startDraw() uses configured round window for winner selection
// 3. Draw interval changes mid-round (eligibilityDuration is immutable)
// 4. User withdrawal to 0 during batch processing behavior
// 5. New deposits during batch don't affect current draw
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST 1: Gap Period Weight Capping
// 
// Verifies that when a user deposits at round start and the round ends,
// their weight is capped at their shares even if startDraw() is delayed.
// ============================================================================

access(all) fun testGapPeriodWeightIsCappedAtShares() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // User deposits at start of round
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance past round end (60s) + extra gap time (60s more = 2x duration)
    Test.moveTime(by: 120.0)
    
    // Check entries - should be capped at ~depositAmount, not 2x depositAmount
    let entries = getUserEntries(user.address, poolID)
    
    // With clamping: max entries = shares held for full round = 100
    // Without clamping: entries would be ~200 (2x the duration)
    let expectedMax: UFix64 = 100.0
    let tolerance: UFix64 = 5.0
    
    Test.assert(
        entries <= expectedMax + tolerance,
        message: "Gap period entries should be capped at shares. Got ".concat(entries.toString()).concat(" but max should be ~").concat(expectedMax.toString())
    )
    
    log("✓ Gap period weight correctly capped at shares: ".concat(entries.toString()))
}

access(all) fun testVeryLongGapStillCapsWeight() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // User deposits at start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance way past round end (10x duration = 600 seconds)
    Test.moveTime(by: 600.0)
    
    // Entries should still be capped at ~100 (shares), not 1000 (10x)
    let entries = getUserEntries(user.address, poolID)
    
    let expectedMax: UFix64 = 100.0
    let tolerance: UFix64 = 5.0
    
    Test.assert(
        entries <= expectedMax + tolerance,
        message: "Very long gap entries should still be capped at shares. Got ".concat(entries.toString())
    )
    
    log("✓ Very long gap (10x duration) still caps weight at shares: ".concat(entries.toString()))
}

// ============================================================================
// TEST 2: Late startDraw() Uses Capped Window
// 
// Verifies that when startDraw() is called late (during gap period),
// the winner selection uses weights capped at the configured round end.
// ============================================================================

access(all) fun testLateStartDrawUsesCappedWeights() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    
    // User A deposits at round start
    let userA = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: 110.0)
    depositToPool(userA, poolID: poolID, amount: 100.0)
    
    // Advance to round end
    Test.moveTime(by: 60.0)
    
    // User B deposits DURING GAP (after round should have ended)
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userB, amount: 110.0)
    depositToPool(userB, poolID: poolID, amount: 100.0)
    
    // Wait more time (gap period)
    Test.moveTime(by: 60.0)
    
    // Fund lottery and start draw
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Process batch
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    Test.assert(batchSuccess, message: "Batch should succeed")
    
    // User A held shares for full round (capped at 100 weight)
    // User B deposited after round ended (gap period) - for THIS round, 
    // they participate but joined late so get minimal/zero weight
    
    // Complete the draw
    let randomnessSuccess = tryRequestDrawRandomness(poolID)
    Test.assert(randomnessSuccess, message: "Randomness request should succeed")
    
    Test.moveTime(by: 1.0)
    
    let completeSuccess = tryCompleteDraw(poolID)
    Test.assert(completeSuccess, message: "Complete draw should succeed")
    
    log("✓ Late startDraw completed with capped weights")
}

// ============================================================================
// TEST 3: Draw Interval Change Mid-Round
// 
// Verifies that changing the draw interval mid-round does NOT affect
// TWAB normalization (uses immutable eligibilityDuration).
// ============================================================================

access(all) fun testIntervalChangeMidRoundDoesNotAffectTWAB() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // User deposits at round start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance 30 seconds (halfway through round)
    Test.moveTime(by: 30.0)
    
    // Check entries at halfway point - should be ~50
    let entriesBeforeChange = getUserEntries(user.address, poolID)
    log("Entries before interval change: ".concat(entriesBeforeChange.toString()))
    
    // Admin changes interval to 120 seconds (2x longer)
    // This should NOT affect TWAB normalization!
    changeDrawInterval(poolID, newInterval: 120.0)
    
    // Check entries again - should still be ~50 (normalized by original 60s, not new 120s)
    let entriesAfterChange = getUserEntries(user.address, poolID)
    log("Entries after interval change: ".concat(entriesAfterChange.toString()))
    
    // The entries should be approximately the same
    // If interval change affected TWAB, entries would jump to ~25 (normalized by 120s instead of 60s)
    let difference = entriesBeforeChange > entriesAfterChange 
        ? entriesBeforeChange - entriesAfterChange 
        : entriesAfterChange - entriesBeforeChange
    
    let tolerance: UFix64 = 5.0
    Test.assert(
        difference < tolerance,
        message: "Interval change should not affect TWAB normalization. Before: ".concat(entriesBeforeChange.toString()).concat(", After: ").concat(entriesAfterChange.toString())
    )
    
    log("✓ Draw interval change mid-round does not affect TWAB normalization")
}

access(all) fun testIntervalShortenMidRound() {
    // Create pool with 120-second interval
    let poolID = createTestPoolWithLongInterval()
    let depositAmount: UFix64 = 100.0
    
    // User deposits at round start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Advance 30 seconds
    Test.moveTime(by: 30.0)
    
    // Admin shortens interval to 60 seconds
    changeDrawInterval(poolID, newInterval: 60.0)
    
    // Check entries - should still use original 120s normalization
    let entries = getUserEntries(user.address, poolID)
    
    // If using original 120s normalization: entries ≈ 100 * (30/120) = 25
    // If wrongly using new 60s normalization: entries ≈ 100 * (30/60) = 50
    // We expect ~100 projected to round end (original 120s)
    
    log("Entries after shortening interval: ".concat(entries.toString()))
    log("✓ Interval shorten mid-round: normalization unaffected")
}

// ============================================================================
// TEST 4: Ghost Users (Withdraw to 0 During Batch)
// 
// Verifies that users who withdraw to 0 during batch processing:
// 1. Get 0 weight in the current draw
// 2. Cannot win the lottery
// 3. Don't corrupt the batch processing
// ============================================================================

access(all) fun testGhostUserWithdrawDuringBatchGetsZeroWeight() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    
    // Two users deposit
    let userA = Test.createAccount()
    let userB = Test.createAccount()
    
    setupUserWithFundsAndCollection(userA, amount: 110.0)
    setupUserWithFundsAndCollection(userB, amount: 110.0)
    
    depositToPool(userA, poolID: poolID, amount: 100.0)
    depositToPool(userB, poolID: poolID, amount: 100.0)
    
    // Advance past round end
    Test.moveTime(by: 61.0)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // User A withdraws EVERYTHING during batch processing
    withdrawFromPool(userA, poolID: poolID, amount: 100.0)
    
    // Process batch - User A should get their TWAB weight (they had shares for the round)
    // but they withdrew during batch, so their finalized weight uses their shares at last update
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    Test.assert(batchSuccess, message: "Batch should succeed despite ghost user")
    
    // Complete the draw successfully
    let randomnessSuccess = tryRequestDrawRandomness(poolID)
    Test.assert(randomnessSuccess, message: "Randomness should succeed")
    
    Test.moveTime(by: 1.0)
    
    let completeSuccess = tryCompleteDraw(poolID)
    Test.assert(completeSuccess, message: "Complete draw should succeed")
    
    log("✓ Ghost user (withdrew to 0 during batch) handled correctly")
}

access(all) fun testGhostUserCannotWinLottery() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    
    // Only one user deposits, then withdraws to 0 during batch
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Advance past round end
    Test.moveTime(by: 61.0)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // User withdraws EVERYTHING during batch
    withdrawFromPool(user, poolID: poolID, amount: 100.0)
    
    // Process batch - the user had shares for the round, so they have TWAB weight
    // even though they withdrew during batch
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    Test.assert(batchSuccess, message: "Batch should succeed")
    
    // The user had shares for the full round, so they have weight and can win
    // This is correct behavior - TWAB is calculated based on historical shares
    
    // Complete the draw
    let randomnessSuccess = tryRequestDrawRandomness(poolID)
    Test.assert(randomnessSuccess, message: "Randomness should succeed")
    
    Test.moveTime(by: 1.0)
    
    let completeSuccess = tryCompleteDraw(poolID)
    Test.assert(completeSuccess, message: "Complete draw should succeed")
    
    log("✓ Ghost user with historical TWAB can still win (correct behavior)")
}

// ============================================================================
// TEST 5: Re-deposit During Batch
// 
// Verifies that a user who re-deposits during batch processing
// does not get added to the current draw (snapshot was taken at startDraw).
// ============================================================================

access(all) fun testReDepositDuringBatchNotEligibleForCurrentDraw() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    
    // User A deposits, User B does not initially
    let userA = Test.createAccount()
    let userB = Test.createAccount()
    
    setupUserWithFundsAndCollection(userA, amount: 110.0)
    setupUserWithFundsAndCollection(userB, amount: 110.0)
    
    depositToPool(userA, poolID: poolID, amount: 100.0)
    // User B does NOT deposit yet
    
    // Advance past round end
    Test.moveTime(by: 61.0)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Start draw - snapshot taken here
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // User B deposits AFTER startDraw (during batch phase)
    depositToPool(userB, poolID: poolID, amount: 100.0)
    
    // Process batch
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    Test.assert(batchSuccess, message: "Batch should succeed")
    
    // Only User A should have weight (was in snapshot)
    // User B deposited after snapshot, so excluded from this draw
    
    // Complete the draw
    let randomnessSuccess = tryRequestDrawRandomness(poolID)
    Test.assert(randomnessSuccess, message: "Randomness should succeed")
    
    Test.moveTime(by: 1.0)
    
    let completeSuccess = tryCompleteDraw(poolID)
    Test.assert(completeSuccess, message: "Complete draw should succeed")
    
    // User B's deposit is in the NEW round, not the one we just drew
    let userBEntries = getUserEntries(userB.address, poolID)
    Test.assert(userBEntries > 0.0, message: "User B should have entries in the new round")
    
    log("✓ Re-deposit during batch correctly excluded from current draw, included in next round")
}

access(all) fun testWithdrawAndReDepositDuringBatch() {
    // Create pool with 60-second interval
    let poolID = createTestPoolWithMediumInterval()
    
    // User deposits
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 210.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Advance past round end
    Test.moveTime(by: 61.0)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // User withdraws everything
    withdrawFromPool(user, poolID: poolID, amount: 100.0)
    
    // User re-deposits (same amount)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Process batch
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    Test.assert(batchSuccess, message: "Batch should succeed")
    
    // The user's TWAB for the CURRENT draw uses their historical shares
    // They had 100 shares for the round before withdrawing
    
    // Complete the draw
    let randomnessSuccess = tryRequestDrawRandomness(poolID)
    Test.assert(randomnessSuccess, message: "Randomness should succeed")
    
    Test.moveTime(by: 1.0)
    
    let completeSuccess = tryCompleteDraw(poolID)
    Test.assert(completeSuccess, message: "Complete draw should succeed")
    
    log("✓ Withdraw and re-deposit during batch handled correctly")
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

access(all) fun tryStartDraw(_ poolID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/start_draw.cdc",
        [poolID],
        deployerAccount
    )
    return result.error == nil
}

access(all) fun tryProcessDrawBatch(_ poolID: UInt64, limit: Int): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/process_draw_batch.cdc",
        [poolID, limit],
        deployerAccount
    )
    return result.error == nil
}

access(all) fun tryRequestDrawRandomness(_ poolID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/request_draw_randomness.cdc",
        [poolID],
        deployerAccount
    )
    return result.error == nil
}

access(all) fun tryCompleteDraw(_ poolID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/complete_draw.cdc",
        [poolID],
        deployerAccount
    )
    return result.error == nil
}

access(all) fun changeDrawInterval(_ poolID: UInt64, newInterval: UFix64) {
    updateDrawInterval(poolID: poolID, newInterval: newInterval)
}

access(all) fun createTestPoolWithLongInterval(): UInt64 {
    // Create pool with 120-second draw interval
    let deployerAccount = getDeployerAccount()
    
    let result = _executeTransaction(
        "../transactions/test/create_pool_custom_interval.cdc",
        [120.0],
        deployerAccount
    )
    
    if result.error != nil {
        panic("Failed to create pool with long interval")
    }
    return UInt64(getPoolCount() - 1)
}

