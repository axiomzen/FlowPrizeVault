import Test
import "test_helpers.cdc"

// ============================================================================
// POOL STATE MACHINE TESTS
// ============================================================================
//
// Tests for the 4 mutually exclusive pool states:
//   1. ROUND_ACTIVE    - Round in progress, timer hasn't expired
//   2. AWAITING_DRAW   - Round ended, waiting for startDraw()
//   3. DRAW_PROCESSING - Draw ceremony in progress
//   4. INTERMISSION    - Draw complete, waiting for startNextRound()
//
// State Transitions:
//   ROUND_ACTIVE → (timer expires) → AWAITING_DRAW
//   AWAITING_DRAW → (startDraw) → DRAW_PROCESSING
//   DRAW_PROCESSING → (completeDraw) → INTERMISSION
//   INTERMISSION → (startNextRound) → ROUND_ACTIVE
//
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Initial State
// ============================================================================

access(all) fun testInitialStateIsRoundActive() {
    // When a pool is created, it should start in ROUND_ACTIVE state
    let poolID = createTestPoolWithShortInterval()

    // Check state string
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))

    // Check individual booleans
    Test.assertEqual(true, isRoundActive(poolID))
    Test.assertEqual(false, isAwaitingDraw(poolID))
    Test.assertEqual(false, isDrawInProgress(poolID))
    Test.assertEqual(false, isInIntermission(poolID))

    // Verify mutual exclusivity
    assertExactlyOneStateTrue(poolID, context: "Initial state")
}

// ============================================================================
// TEST: Transition to AWAITING_DRAW
// ============================================================================

access(all) fun testTransitionToAwaitingDraw() {
    // After round timer expires, state should be AWAITING_DRAW
    // Use medium interval so round doesn't expire during setup
    let poolID = createTestPoolWithMediumInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 5.0)

    // Initially in ROUND_ACTIVE
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Before timer expires")

    // Advance time past the 60s draw interval
    Test.moveTime(by: 70.0)

    // Now should be AWAITING_DRAW
    Test.assertEqual("AWAITING_DRAW", getPoolState(poolID))
    Test.assertEqual(false, isRoundActive(poolID))
    Test.assertEqual(true, isAwaitingDraw(poolID))
    Test.assertEqual(false, isDrawInProgress(poolID))
    Test.assertEqual(false, isInIntermission(poolID))

    // Verify mutual exclusivity
    assertExactlyOneStateTrue(poolID, context: "After timer expires")
}

// ============================================================================
// TEST: Transition to DRAW_PROCESSING
// ============================================================================

access(all) fun testTransitionToDrawProcessing() {
    // After startDraw(), state should be DRAW_PROCESSING
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 5.0)

    // Advance time past the draw interval
    Test.moveTime(by: 10.0)

    // Verify we're in AWAITING_DRAW
    Test.assertEqual("AWAITING_DRAW", getPoolState(poolID))

    // Start the draw
    startDraw(user1, poolID: poolID)

    // Now should be DRAW_PROCESSING
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    Test.assertEqual(false, isRoundActive(poolID))
    Test.assertEqual(false, isAwaitingDraw(poolID))
    Test.assertEqual(true, isDrawInProgress(poolID))
    Test.assertEqual(false, isInIntermission(poolID))

    // Verify mutual exclusivity
    assertExactlyOneStateTrue(poolID, context: "After startDraw")
}

// ============================================================================
// TEST: DRAW_PROCESSING persists through batch processing
// ============================================================================

access(all) fun testDrawProcessingDuringBatchProcessing() {
    // State should remain DRAW_PROCESSING during batch processing
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()

    // Setup multiple users
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    setupUserWithFundsAndCollection(user2, amount: 100.0)
    setupUserWithFundsAndCollection(user3, amount: 100.0)

    depositToPool(user1, poolID: poolID, amount: 10.0)
    depositToPool(user2, poolID: poolID, amount: 10.0)
    depositToPool(user3, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and start draw
    Test.moveTime(by: 10.0)
    startDraw(user1, poolID: poolID)

    // Should be DRAW_PROCESSING
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "After startDraw with multiple users")

    // Process batch (still in DRAW_PROCESSING)
    processDrawBatch(user1, poolID: poolID, limit: 1)
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "During batch processing")

    // Process remaining batches
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)

    // Still DRAW_PROCESSING until completeDraw
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "After batch complete, before completeDraw")
}

// ============================================================================
// TEST: Transition to INTERMISSION
// ============================================================================

access(all) fun testTransitionToIntermission() {
    // After completeDraw(), state should be INTERMISSION
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and start draw
    Test.moveTime(by: 10.0)
    startDraw(user1, poolID: poolID)

    // Process batches
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)

    // Commit blocks for randomness
    commitBlocksForRandomness()

    // Complete the draw
    completeDraw(user1, poolID: poolID)

    // Now should be INTERMISSION
    Test.assertEqual("INTERMISSION", getPoolState(poolID))
    Test.assertEqual(false, isRoundActive(poolID))
    Test.assertEqual(false, isAwaitingDraw(poolID))
    Test.assertEqual(false, isDrawInProgress(poolID))
    Test.assertEqual(true, isInIntermission(poolID))

    // Verify mutual exclusivity
    assertExactlyOneStateTrue(poolID, context: "After completeDraw")
}

// ============================================================================
// TEST: Transition back to ROUND_ACTIVE
// ============================================================================

access(all) fun testTransitionBackToRoundActive() {
    // After startNextRound(), state should be ROUND_ACTIVE again
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool
    fundPrizePool(poolID, amount: 5.0)

    // Execute full draw to intermission
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Verify we're in INTERMISSION
    Test.assertEqual("INTERMISSION", getPoolState(poolID))

    // Start next round
    startNextRound(user1, poolID: poolID)

    // Now should be back to ROUND_ACTIVE
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))
    Test.assertEqual(true, isRoundActive(poolID))
    Test.assertEqual(false, isAwaitingDraw(poolID))
    Test.assertEqual(false, isDrawInProgress(poolID))
    Test.assertEqual(false, isInIntermission(poolID))

    // Verify mutual exclusivity
    assertExactlyOneStateTrue(poolID, context: "After startNextRound")
}

// ============================================================================
// TEST: Full lifecycle through multiple cycles
// ============================================================================

access(all) fun testFullLifecycleMultipleCycles() {
    // Test complete state machine through 2 full cycles
    // Use medium interval (60s) so the round doesn't expire during setup
    let poolID = createTestPoolWithMediumInterval()
    let user1 = Test.createAccount()

    // State 1: ROUND_ACTIVE (initial) - check immediately after pool creation
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for multiple draws
    fundPrizePool(poolID, amount: 20.0)

    // === CYCLE 1 ===

    // Still ROUND_ACTIVE after setup
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Initial")

    // State 2: AWAITING_DRAW (timer expires) - use 70s to exceed 60s interval
    Test.moveTime(by: 70.0)
    Test.assertEqual("AWAITING_DRAW", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Timer expired")

    // State 3: DRAW_PROCESSING (startDraw)
    startDraw(user1, poolID: poolID)
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Draw started")

    // Still DRAW_PROCESSING (batch processing)
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Batch complete")

    // State 4: INTERMISSION (completeDraw)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    Test.assertEqual("INTERMISSION", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Draw complete")

    // Back to State 1: ROUND_ACTIVE (startNextRound)
    startNextRound(user1, poolID: poolID)
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 1: Next round started")

    // === CYCLE 2 ===

    // Fund prize pool again for second draw (prize was distributed in cycle 1)
    fundPrizePool(poolID, amount: 5.0)

    // State 2: AWAITING_DRAW - use 70s to exceed 60s interval
    Test.moveTime(by: 70.0)
    Test.assertEqual("AWAITING_DRAW", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 2: Timer expired")

    // State 3: DRAW_PROCESSING
    startDraw(user1, poolID: poolID)
    Test.assertEqual("DRAW_PROCESSING", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 2: Draw started")

    // Complete draw to intermission
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)

    // State 4: INTERMISSION
    Test.assertEqual("INTERMISSION", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 2: Draw complete")

    // Back to State 1: ROUND_ACTIVE
    startNextRound(user1, poolID: poolID)
    Test.assertEqual("ROUND_ACTIVE", getPoolState(poolID))
    assertExactlyOneStateTrue(poolID, context: "Cycle 2: Next round started")
}

// ============================================================================
// TEST: States are mutually exclusive at all times
// ============================================================================

access(all) fun testStatesAreMutuallyExclusive() {
    // Verify that at every point in the lifecycle, exactly one state is true
    // Use medium interval so round doesn't expire during setup
    let poolID = createTestPoolWithMediumInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)
    fundPrizePool(poolID, amount: 5.0)

    // Check at each stage
    assertExactlyOneStateTrue(poolID, context: "After creation")

    Test.moveTime(by: 30.0)  // Partial time elapsed (half of 60s)
    assertExactlyOneStateTrue(poolID, context: "During round (partial time)")

    Test.moveTime(by: 60.0)  // Timer expired
    assertExactlyOneStateTrue(poolID, context: "After timer expired")

    startDraw(user1, poolID: poolID)
    assertExactlyOneStateTrue(poolID, context: "After startDraw")

    // Process all batches (with 1 user, completes in one call)
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    assertExactlyOneStateTrue(poolID, context: "After batch complete")

    commitBlocksForRandomness()
    assertExactlyOneStateTrue(poolID, context: "After randomness commit")

    completeDraw(user1, poolID: poolID)
    assertExactlyOneStateTrue(poolID, context: "After completeDraw")

    startNextRound(user1, poolID: poolID)
    assertExactlyOneStateTrue(poolID, context: "After startNextRound")
}

// ============================================================================
// TEST: getPoolState returns correct string values
// ============================================================================

access(all) fun testGetPoolStateReturnsCorrectStrings() {
    // Verify getPoolState() returns exactly the expected strings
    // Use medium interval so round doesn't expire during setup
    let poolID = createTestPoolWithMediumInterval()
    let user1 = Test.createAccount()

    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)
    fundPrizePool(poolID, amount: 5.0)

    // ROUND_ACTIVE
    let state1 = getPoolState(poolID)
    Test.assertEqual("ROUND_ACTIVE", state1)

    // AWAITING_DRAW - use 70s to exceed 60s interval
    Test.moveTime(by: 70.0)
    let state2 = getPoolState(poolID)
    Test.assertEqual("AWAITING_DRAW", state2)

    // DRAW_PROCESSING
    startDraw(user1, poolID: poolID)
    let state3 = getPoolState(poolID)
    Test.assertEqual("DRAW_PROCESSING", state3)

    // INTERMISSION
    processAllDrawBatches(user1, poolID: poolID, batchSize: 1000)
    commitBlocksForRandomness()
    completeDraw(user1, poolID: poolID)
    let state4 = getPoolState(poolID)
    Test.assertEqual("INTERMISSION", state4)
}
