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
// TESTS - Basic Round Creation
// ============================================================================

access(all) fun testNewPoolHasRoundIDOne() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(1), state["currentRoundID"]! as! UInt64)
}

access(all) fun testNewPoolRoundHasStartTime() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    let roundStartTime = state["roundStartTime"]! as! UFix64
    Test.assert(roundStartTime > 0.0, message: "Round should have a start time")
}

access(all) fun testNewPoolRoundHasDuration() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    let roundDuration = state["roundDuration"]! as! UFix64
    Test.assert(roundDuration > 0.0, message: "Round should have a duration")
}

access(all) fun testNewPoolRoundNotEnded() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    let isRoundEnded = state["isRoundEnded"]! as! Bool
    Test.assertEqual(false, isRoundEnded)
}

// ============================================================================
// TESTS - Round Ending
// ============================================================================

access(all) fun testRoundEndsAfterDuration() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Initially not ended
    let stateBeforeTime = getPoolInitialState(poolID)
    Test.assertEqual(false, stateBeforeTime["isRoundEnded"]! as! Bool)
    
    // Advance time past round duration
    Test.moveTime(by: 61.0)
    
    // Now round should be ended
    let stateAfterTime = getPoolInitialState(poolID)
    Test.assertEqual(true, stateAfterTime["isRoundEnded"]! as! Bool)
}

access(all) fun testCanDrawNowAfterRoundEnds() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant for prize
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Initially cannot draw
    let statusBefore = getDrawStatus(poolID)
    Test.assertEqual(false, statusBefore["canDrawNow"]! as! Bool)
    
    // Advance past round duration (60+ seconds for medium interval)
    Test.moveTime(by: 61.0)
    
    // Now can draw
    let statusAfter = getDrawStatus(poolID)
    Test.assertEqual(true, statusAfter["canDrawNow"]! as! Bool)
}

// ============================================================================
// TESTS - Earned Entries (TWAB)
// Entries use an "earned entries" model: entries grow over time as the user
// holds shares. At any point, earnedEntries = getCurrentTWAB(now) × (elapsed / duration).
// At round end, earned entries equal the old projected entries.
// ============================================================================

access(all) fun testNearStartDepositGetsNearFullEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Deposit near start of round (after account setup transactions)
    // Note: Each transaction advances the block timestamp by ~1 second,
    // so by the time we deposit, ~1 second has passed since round start.
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end so earned entries fully accumulate
    Test.moveTime(by: 58.0)

    // Check entries - should be ~59/60 of deposit amount due to setup delay
    let entries = getUserEntries(user.address, poolID)

    // Expected: ~96-98 entries (100 × ~58/60, with timing variance from
    // test framework overhead: account creation, deposit tx, moveTime all advance block time)
    let expectedEntries: UFix64 = 97.0
    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries ? entries - expectedEntries : expectedEntries - entries

    Test.assert(
        difference < tolerance,
        message: "Near-start deposit should get ~97 entries. Got ".concat(entries.toString())
    )
}

access(all) fun testHalfRoundDepositGetsHalfEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Advance halfway through round (30s of 60s)
    Test.moveTime(by: 30.0)

    // Deposit halfway through
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end so earned entries fully accumulate
    Test.moveTime(by: 28.0)

    // Check entries - should be approximately half (held for half the round)
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount / 2.0

    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries ? entries - expectedEntries : expectedEntries - entries

    Test.assert(
        difference < tolerance,
        message: "Deposit at half round should get ~half entries. Expected ~".concat(expectedEntries.toString()).concat(", got ").concat(entries.toString())
    )
}

access(all) fun testWithdrawalReducesEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 50.0

    // Deposit at start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to 50% of round and withdraw half
    Test.moveTime(by: 30.0)
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)

    // Advance to round end to check final earned entries
    Test.moveTime(by: 29.0)
    let entries = getUserEntries(user.address, poolID)

    // If user had NOT withdrawn: entries would be ~100 (held full round)
    // With withdrawal at 50%: 100 shares x 30s + 50 shares x 30s = 75 average -> ~75 entries
    // So entries < depositAmount proves withdrawal reduced entries
    Test.assert(
        entries < depositAmount - 5.0,
        message: "Withdrawal should reduce entries below full-round value. Got: ".concat(entries.toString())
    )
    Test.assert(
        entries > 0.0,
        message: "Should still have some entries. Got: ".concat(entries.toString())
    )
}

// ============================================================================
// TESTS - Round Transitions
// ============================================================================

access(all) fun testRoundIDIncrementsAfterDraw() {
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
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Complete a full draw (4-phase: start -> batch -> randomness -> complete)
    executeFullDraw(participant, poolID: poolID)
    
    // Check round ID incremented
    let stateAfter = getPoolInitialState(poolID)
    let roundIDAfter = stateAfter["currentRoundID"]! as! UInt64
    
    Test.assertEqual(roundIDBefore + 1, roundIDAfter)
}

access(all) fun testEntriesResetAfterDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: depositAmount + 10.0)
    depositToPool(participant, poolID: poolID, amount: depositAmount)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Wait for round to end
    Test.moveTime(by: 61.0)

    // Complete a full draw (4-phase: start -> batch -> randomness -> complete)
    executeFullDraw(participant, poolID: poolID)

    // In the earned-entries model, entries in a new round start near 0 and grow.
    // Advance some time in the new round so entries accumulate.
    Test.moveTime(by: 30.0)

    // Check entries in new round - should have earned some entries by now
    let entries = getUserEntries(participant.address, poolID)

    // User still has their shares, so should have entries in new round
    Test.assert(
        entries > 0.0,
        message: "User should have entries in new round after some time"
    )
}

// ============================================================================
// TESTS - Gap Period Handling
// ============================================================================

access(all) fun testGapDepositGetsFullNextRoundEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // First user deposits at start
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)

    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Wait for round to end but don't start draw
    Test.moveTime(by: 61.0)

    // New user deposits during gap period
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)

    // Complete a full draw (4-phase: start -> batch -> randomness -> complete)
    // This creates new round where gap users get lazy initialization (full-round credit)
    executeFullDraw(existingUser, poolID: poolID)

    // In earned-entries model, entries start near 0 in the new round.
    // Advance to near end of new round so entries fully accumulate.
    Test.moveTime(by: 58.0)

    // Gap user should have full entries in the new round via lazy fallback
    let gapUserEntries = getUserEntries(gapUser.address, poolID)

    // They deposited at the start of the new round, so should get ~full entries
    let tolerance: UFix64 = 5.0
    let difference = gapUserEntries > depositAmount ? gapUserEntries - depositAmount : depositAmount - gapUserEntries

    Test.assert(
        difference < tolerance,
        message: "Gap user should get ~full entries in new round. Got ".concat(gapUserEntries.toString())
    )
}

// ============================================================================
// TESTS - Additional TWAB Calculation Tests
// ============================================================================

access(all) fun testExactlyHalfRoundDepositTWAB() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0

    // Advance exactly to halfway point
    Test.moveTime(by: 30.0)

    // Deposit at exactly 50%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end so earned entries fully accumulate
    Test.moveTime(by: 28.0)

    // Check entries - should be approximately half (held for half the round)
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount / 2.0 // 50 entries

    // Use larger tolerance (10.0) to account for timing variance from test framework
    // overhead (account creation, transaction execution advance block time)
    let tolerance: UFix64 = 10.0
    let difference = entries > expectedEntries
        ? entries - expectedEntries
        : expectedEntries - entries

    Test.assert(
        difference < tolerance,
        message: "Exact half-round deposit should get ~50 entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testQuarterRoundDepositTWAB() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0

    // Advance to 25% of round (15 seconds)
    Test.moveTime(by: 15.0)

    // Deposit at 25%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end so earned entries fully accumulate
    Test.moveTime(by: 43.0)

    // Check entries - should be approximately 75% of deposit (held for 75% of round)
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount * 0.75 // 75 entries (75% of round held)

    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries
        ? entries - expectedEntries
        : expectedEntries - entries

    Test.assert(
        difference < tolerance,
        message: "Quarter-round deposit should get ~75 entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testThreeQuarterRoundDepositTWAB() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0

    // Advance to 75% of round (45 seconds)
    Test.moveTime(by: 45.0)

    // Deposit at 75%
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end so earned entries fully accumulate
    Test.moveTime(by: 13.0)

    // Check entries - should be approximately 25% of deposit (held for 25% of round)
    let entries = getUserEntries(user.address, poolID)
    let expectedEntries = depositAmount * 0.25 // 25 entries (25% of round held)

    let tolerance: UFix64 = 5.0
    let difference = entries > expectedEntries
        ? entries - expectedEntries
        : expectedEntries - entries

    Test.assert(
        difference < tolerance,
        message: "Three-quarter-round deposit should get ~25 entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testDepositAtEndGetsMinimalEntries() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Advance to near end of round (58 seconds of 60)
    Test.moveTime(by: 58.0)
    
    // Deposit with ~2 seconds remaining
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Check entries - should be very small
    let entries = getUserEntries(user.address, poolID)
    
    // Expected: ~2/60 = ~3.33 entries (with some tolerance for block timing)
    let expectedMax: UFix64 = 10.0 // Should be less than 10% of deposit
    Test.assert(
        entries < expectedMax,
        message: "Near-end deposit should get minimal entries. Got: ".concat(entries.toString())
    )
}

// ============================================================================
// TESTS - Withdrawal Impact on Earned Entries (TWAB)
// These tests verify withdrawals reduce earned entries at round end compared
// to the full-round value the user would have had without withdrawing.
// ============================================================================

access(all) fun testPartialWithdrawalReducesTWAB() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 25.0

    // Setup user with deposit at start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to 50% of round
    Test.moveTime(by: 30.0)

    // Withdraw 25%
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)

    // Advance to round end
    Test.moveTime(by: 29.0)
    let entries = getUserEntries(user.address, poolID)

    // Without withdrawal: entries ~ 100 (held 100 shares for full round)
    // With withdrawal at 50%: 100 x 30/60 + 75 x 30/60 = 50 + 37.5 = 87.5
    // So entries should be less than full-round value
    Test.assert(
        entries < depositAmount - 5.0,
        message: "Partial withdrawal should reduce entries below full-round value. Got: ".concat(entries.toString())
    )
    Test.assert(
        entries > 50.0,
        message: "Should still have significant entries. Got: ".concat(entries.toString())
    )
}

access(all) fun testWithdrawalDoesNotAffectOtherUsers() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Setup two users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()

    setupUserWithFundsAndCollection(user1, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)

    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)

    // Advance time and user1 withdraws
    Test.moveTime(by: 30.0)
    withdrawFromPool(user1, poolID: poolID, amount: 50.0)

    // Advance to round end
    Test.moveTime(by: 29.0)

    // User2's entries should be ~full (they held 100 shares for ~full round)
    let user2Entries = getUserEntries(user2.address, poolID)

    let tolerance: UFix64 = 5.0
    let difference = user2Entries > depositAmount ? user2Entries - depositAmount : depositAmount - user2Entries

    Test.assert(
        difference < tolerance,
        message: "User2 entries should be ~100 (unaffected by User1 withdrawal). Got: ".concat(user2Entries.toString())
    )
}

access(all) fun testMultipleWithdrawalsAccumulateImpact() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Setup user with deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Multiple small withdrawals over time
    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0) // 90 shares

    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0) // 80 shares

    Test.moveTime(by: 10.0)
    withdrawFromPool(user, poolID: poolID, amount: 10.0) // 70 shares

    // Advance to round end
    Test.moveTime(by: 29.0)
    let finalEntries = getUserEntries(user.address, poolID)

    // Without any withdrawals: entries ~ 100
    // With progressive withdrawals: 100x10/60 + 90x10/60 + 80x10/60 + 70x30/60
    //   ~ 16.67 + 15.0 + 13.33 + 35.0 ~ 80 (tolerance needed for block timing)
    // Key: final entries should be significantly less than 100
    Test.assert(
        finalEntries < depositAmount - 10.0,
        message: "Multiple withdrawals should reduce entries below full-round value. Got: ".concat(finalEntries.toString())
    )
    Test.assert(
        finalEntries > 50.0,
        message: "Should still have substantial entries. Got: ".concat(finalEntries.toString())
    )
}

// ============================================================================
// TESTS - Entry Calculation Edge Cases
// ============================================================================

access(all) fun testFullWithdrawalThenRedepositTWAB() {
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
    
    // Move time slightly to ensure there is a gap where the user has a balance of 0
    Test.moveTime(by: 5.0)
    // redeposit
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // DEBUG: Log entries after redeposit
    let entriesAfterRedeposit = getUserEntries(user.address, poolID)
    log("DEBUG: Entries after redeposit: ".concat(entriesAfterRedeposit.toString()))
    log("DEBUG: Expected entries < depositAmount (".concat(depositAmount.toString()).concat(")"))
    
    // Check entries - should account for the gap when balance was 0
    let entries = getUserEntries(user.address, poolID)
    
    // User should have entries (not zero)
    Test.assert(entries > 0.0, message: "Should have entries after redeposit")
    
    // Entries should be less than if they never withdrew
    // (accounting for 0-balance period)
    Test.assert(entries < depositAmount, message: "Entries should be less than deposit due to withdrawal gap")
}

access(all) fun testEntriesConsistentWithShareBalance() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0

    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)

    // Advance to round end to get full earned entries
    Test.moveTime(by: 58.0)

    // Get entries and balance
    let entries = getUserEntries(user.address, poolID)

    // At round end, earned entries for a full-round deposit ~ share balance
    let tolerance: UFix64 = 10.0
    let difference = entries > depositAmount
        ? entries - depositAmount
        : depositAmount - entries

    Test.assert(
        difference < tolerance,
        message: "Entries at round end should be close to deposit for early depositors. Got: ".concat(entries.toString())
    )
}

access(all) fun testZeroBalanceHasZeroEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two users - one stays, one leaves
    let stayingUser = Test.createAccount()
    let leavingUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(stayingUser, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(leavingUser, amount: depositAmount + 10.0)
    
    depositToPool(stayingUser, poolID: poolID, amount: depositAmount)
    depositToPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Leaving user withdraws everything
    withdrawFromPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Leaving user should have 0 balance
    let balance = getUserPoolBalance(leavingUser.address, poolID)
    Test.assertEqual(0.0, balance["totalBalance"]!)
    
    // Fund prize and execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(stayingUser, poolID: poolID)
    
    // Staying user should have won (leaving user had 0 entries)
    let stayingPrizes = getUserPrizes(stayingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, stayingPrizes["totalEarnedPrizes"]!)
}
