import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Intermission State Detection
// ============================================================================

access(all) fun testPoolNotInIntermissionAfterCreation() {
    // Newly created pools start with an active round, not in intermission
    let poolID = createTestPoolWithShortInterval()

    let inIntermission = isInIntermission(poolID)
    Test.assertEqual(false, inIntermission)
}

access(all) fun testPoolEntersIntermissionAfterCompleteDraw() {
    // Pool should enter intermission after completeDraw
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time past draw interval
    Test.moveTime(by: 10.0)

    // Execute draw but leave in intermission
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Should be in intermission now
    let inIntermission = isInIntermission(poolID)
    Test.assertEqual(true, inIntermission)
}

access(all) fun testPoolExitsIntermissionAfterStartNextRound() {
    // Pool should exit intermission after startNextRound
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user and deposit
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time past draw interval
    Test.moveTime(by: 10.0)

    // Execute draw (leaves in intermission)
    executeFullDrawWithIntermission(user1, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Start next round
    startNextRound(user1, poolID: poolID)

    // Should not be in intermission anymore
    let inIntermission = isInIntermission(poolID)
    Test.assertEqual(false, inIntermission)
}

// ============================================================================
// TESTS - Deposits During Intermission
// ============================================================================

access(all) fun testDepositsAllowedDuringIntermission() {
    // Deposits should be allowed during intermission
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()

    // Setup users
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    setupUserWithFundsAndCollection(user2, amount: 100.0)

    // First user deposits
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and execute draw
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Pool is in intermission
    Test.assertEqual(true, isInIntermission(poolID))

    // Second user should be able to deposit during intermission
    depositToPool(user2, poolID: poolID, amount: 20.0)

    // Verify deposit succeeded
    let balance = getUserPoolBalance(user2.address, poolID)
    Test.assert(balance["totalBalance"]! > 0.0, message: "User should have balance after deposit during intermission")
}

access(all) fun testIntermissionDepositorGetsFullEntriesForNextRound() {
    // Depositors during intermission get their share balance as entries
    // (representing their full weight at the start of next round)
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()

    // Setup users
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    setupUserWithFundsAndCollection(user2, amount: 100.0)

    // First user deposits
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and execute draw
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Second user deposits during intermission
    depositToPool(user2, poolID: poolID, amount: 10.0)

    // During intermission, user entries should equal their share balance
    // (their full entries for the next round)
    let entriesDuringIntermission = getUserEntries(user2.address, poolID)
    Test.assert(entriesDuringIntermission > 0.0, message: "User should have entries during intermission equal to share balance")

    // Start next round
    startNextRound(user1, poolID: poolID)

    // Now wait for some time to pass
    Test.moveTime(by: 5.0)

    // User2 should still have TWAB weight (prorated based on time in round)
    let entriesAfterRoundStart = getUserEntries(user2.address, poolID)
    Test.assert(entriesAfterRoundStart > 0.0, message: "User should have entries after next round starts")
}

// ============================================================================
// TESTS - Withdrawals During Intermission
// ============================================================================

access(all) fun testWithdrawalsAllowedDuringIntermission() {
    // Withdrawals should be allowed during intermission
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)

    // Deposit
    depositToPool(user1, poolID: poolID, amount: 50.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and execute draw
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Pool is in intermission
    Test.assertEqual(true, isInIntermission(poolID))

    // User should be able to withdraw during intermission
    withdrawFromPool(user1, poolID: poolID, amount: 20.0)

    // Verify withdrawal succeeded
    let balance = getUserPoolBalance(user1.address, poolID)
    Test.assert(balance["totalBalance"]! < 50.0, message: "Balance should be reduced after withdrawal")
}

// ============================================================================
// TESTS - Draw Operations During Intermission
// ============================================================================

access(all) fun testStartDrawBlockedDuringIntermission() {
    // startDraw should fail during intermission (no active round)
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time and execute draw
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Pool is in intermission
    Test.assertEqual(true, isInIntermission(poolID))

    // Advance time again
    Test.moveTime(by: 10.0)

    // canDrawNow should return false during intermission
    let drawStatus = getDrawStatus(poolID)
    let canDraw = drawStatus["canDrawNow"] as? Bool ?? true
    Test.assertEqual(false, canDraw)
}

// ============================================================================
// TESTS - Backwards Compatibility
// ============================================================================

access(all) fun testExecuteFullDrawStartsNextRoundAutomatically() {
    // executeFullDraw should start next round for backwards compatibility
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Advance time
    Test.moveTime(by: 10.0)

    // Execute full draw (should auto-start next round)
    executeFullDraw(user1, poolID: poolID)

    // Should NOT be in intermission (backwards compatible)
    let inIntermission = isInIntermission(poolID)
    Test.assertEqual(false, inIntermission)
}

// ============================================================================
// TESTS - Multiple Draw Cycles
// ============================================================================

access(all) fun testMultipleDrawCyclesWithIntermission() {
    // Test multiple draw cycles with explicit intermission handling
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for all draws
    fundPrizePool(poolID, amount: 15.0)

    // First draw cycle
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Start next round
    startNextRound(user1, poolID: poolID)
    Test.assertEqual(false, isInIntermission(poolID))

    // Fund prize pool for second draw
    fundPrizePool(poolID, amount: 5.0)

    // Second draw cycle
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))

    // Start next round again
    startNextRound(user1, poolID: poolID)
    Test.assertEqual(false, isInIntermission(poolID))

    // Fund prize pool for third draw
    fundPrizePool(poolID, amount: 5.0)

    // Third draw cycle
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)
    Test.assertEqual(true, isInIntermission(poolID))
}

// ============================================================================
// TESTS - Round ID Progression
// ============================================================================

access(all) fun testRoundIDProgressesCorrectly() {
    // Verify round IDs progress correctly through intermission
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Get initial round ID
    var drawStatus = getDrawStatus(poolID)
    let initialRoundID = drawStatus["currentRoundID"] as? UInt64 ?? 0
    Test.assertEqual(UInt64(1), initialRoundID)

    // Execute first draw cycle
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // During intermission, round ID should be the last completed round ID (1)
    drawStatus = getDrawStatus(poolID)
    let intermissionRoundID = drawStatus["currentRoundID"] as? UInt64 ?? 999
    Test.assertEqual(UInt64(1), intermissionRoundID)

    // Start next round
    startNextRound(user1, poolID: poolID)

    // Round ID should have incremented
    drawStatus = getDrawStatus(poolID)
    let newRoundID = drawStatus["currentRoundID"] as? UInt64 ?? 0
    Test.assertEqual(initialRoundID + 1, newRoundID)
}

// ============================================================================
// TESTS - Emergency State During Intermission
// ============================================================================

access(all) fun testEmergencyStateDuringIntermission() {
    // Intermission and emergency states are orthogonal
    let poolID = createTestPoolWithShortInterval()
    let user1 = Test.createAccount()

    // Setup user
    setupUserWithFundsAndCollection(user1, amount: 100.0)
    depositToPool(user1, poolID: poolID, amount: 10.0)

    // Fund prize pool for draw
    fundPrizePool(poolID, amount: 5.0)

    // Execute draw to enter intermission
    Test.moveTime(by: 10.0)
    executeFullDrawWithIntermission(user1, poolID: poolID)

    // Verify in intermission but Normal state
    Test.assertEqual(true, isInIntermission(poolID))
    Test.assertEqual(UInt8(0), getPoolEmergencyState(poolID))  // Normal = 0

    // Enable emergency mode while in intermission
    enablePoolEmergencyMode(poolID, reason: "Test during intermission")

    // Should still be in intermission AND in emergency mode
    Test.assertEqual(true, isInIntermission(poolID))
    Test.assertEqual(UInt8(2), getPoolEmergencyState(poolID))  // EmergencyMode = 2

    // Disable emergency mode
    disablePoolEmergencyMode(poolID)

    // Should still be in intermission
    Test.assertEqual(true, isInIntermission(poolID))
    Test.assertEqual(UInt8(0), getPoolEmergencyState(poolID))
}

