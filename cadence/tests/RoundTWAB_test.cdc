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
    
    // Setup participant for lottery
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
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
// TESTS - Cumulative TWAB
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
    
    // Check entries - should be ~59/60 of deposit amount due to setup delay
    let entries = getUserEntries(user.address, poolID)
    
    // Expected: 100 * (59/60) ≈ 98.33 entries
    // Allow tolerance for timing variations across test transactions
    let expectedEntries: UFix64 = 98.33
    let tolerance: UFix64 = 2.0
    let difference = entries > expectedEntries ? entries - expectedEntries : expectedEntries - entries
    
    Test.assert(
        difference < tolerance,
        message: "Near-start deposit should get ~98 entries. Got ".concat(entries.toString())
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
    
    // Check entries - should be approximately half
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
    
    // Deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Get initial entries
    let entriesBefore = getUserEntries(user.address, poolID)
    
    // Withdraw half
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Get new entries
    let entriesAfter = getUserEntries(user.address, poolID)
    
    // Entries should be less than before
    Test.assert(
        entriesAfter < entriesBefore,
        message: "Withdrawal should reduce entries. Before: ".concat(entriesBefore.toString()).concat(", after: ").concat(entriesAfter.toString())
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
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
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
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Complete a full draw (4-phase: start -> batch -> randomness -> complete)
    executeFullDraw(participant, poolID: poolID)
    
    // Check entries in new round - should be projected for full new round
    let entries = getUserEntries(participant.address, poolID)
    
    // User still has their shares, so should have entries in new round
    Test.assert(
        entries > 0.0,
        message: "User should have entries in new round"
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
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end but don't start draw
    Test.moveTime(by: 61.0)
    
    // New user deposits during gap period
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Complete a full draw (4-phase: start -> batch -> randomness -> complete)
    // This creates new round where gap users get lazy initialization (full-round credit)
    executeFullDraw(existingUser, poolID: poolID)
    
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

    // Check entries - should be approximately half
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

access(all) fun testThreeQuarterRoundDepositTWAB() {
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
// TESTS - Withdrawal Impact on TWAB
// ============================================================================

access(all) fun testPartialWithdrawalReducesTWAB() {
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
        message: "Entries should decrease after partial withdrawal. Before: "
            .concat(entriesBefore.toString())
            .concat(", After: ").concat(entriesAfter.toString())
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
        message: "User2 entries should not be affected by User1's withdrawal"
    )
}

access(all) fun testMultipleWithdrawalsAccumulateImpact() {
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
    
    // Each withdrawal should progressively reduce entries
    Test.assert(entriesAfter1 < entriesStart, message: "First withdrawal should reduce entries")
    Test.assert(entriesAfter2 < entriesAfter1, message: "Second withdrawal should further reduce entries")
    Test.assert(entriesAfter3 < entriesAfter2, message: "Third withdrawal should further reduce entries")
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
    
    // Get entries and balance
    let entries = getUserEntries(user.address, poolID)
    let balance = getUserPoolBalance(user.address, poolID)
    
    // Entries should be proportional to balance (for early-round deposit)
    // User deposited 100 near start, should have ~100 entries
    let tolerance: UFix64 = 10.0
    let difference = entries > depositAmount 
        ? entries - depositAmount 
        : depositAmount - entries
    
    Test.assert(
        difference < tolerance,
        message: "Entries should be close to deposit for early depositors. Got: ".concat(entries.toString())
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
    
    // Fund lottery and execute draw
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(stayingUser, poolID: poolID)
    
    // Staying user should have won (leaving user had 0 entries)
    let stayingPrizes = getUserPrizes(stayingUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, stayingPrizes["totalEarnedPrizes"]!)
}
