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
// TESTS - Basic Gap Period Operations
// ============================================================================

access(all) fun testGapPeriodDeposit() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial user to ensure pool has activity
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Verify we're in gap period (round ended but draw not started)
    let stateInGap = getPoolInitialState(poolID)
    Test.assertEqual(true, stateInGap["isRoundEnded"]! as! Bool)
    
    // New user deposits during gap period
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Verify deposit succeeded
    let balance = getUserPoolBalance(gapUser.address, poolID)
    Test.assert(balance["totalBalance"]! > 0.0, message: "Gap user should have balance after deposit")
}

access(all) fun testGapPeriodWithdrawal() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 50.0
    
    // Setup user and deposit before gap
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Get balance before withdrawal
    let balanceBefore = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    
    // Withdraw during gap period
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Verify withdrawal succeeded
    let balanceAfter = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    Test.assert(balanceAfter < balanceBefore, message: "Balance should decrease after withdrawal in gap")
}

access(all) fun testGapPeriodDepositThenWithdraw() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial user
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // New user deposits during gap
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Same user withdraws partially during gap
    withdrawFromPool(gapUser, poolID: poolID, amount: 50.0)
    
    // Verify final balance is deposit - withdrawal
    let balance = getUserPoolBalance(gapUser.address, poolID)
    let expectedBalance = depositAmount - 50.0
    let tolerance: UFix64 = 0.01
    let difference = balance["totalBalance"]! > expectedBalance 
        ? balance["totalBalance"]! - expectedBalance 
        : expectedBalance - balance["totalBalance"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should be ~50 after deposit 100, withdraw 50. Got: ".concat(balance["totalBalance"]!.toString())
    )
}

access(all) fun testGapPeriodWithdrawToZero() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup two users - one to maintain pool activity
    let stayingUser = Test.createAccount()
    let leavingUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(stayingUser, amount: depositAmount + 10.0)
    setupUserWithFundsAndCollection(leavingUser, amount: depositAmount + 10.0)
    
    depositToPool(stayingUser, poolID: poolID, amount: depositAmount)
    depositToPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Leaving user withdraws everything during gap
    withdrawFromPool(leavingUser, poolID: poolID, amount: depositAmount)
    
    // Verify user has zero balance
    let balance = getUserPoolBalance(leavingUser.address, poolID)
    Test.assertEqual(0.0, balance["totalBalance"]!)
}

// ============================================================================
// TESTS - Extended Gap Periods
// ============================================================================

access(all) fun testMultipleRoundDurationsInGap() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for MULTIPLE round durations (10x the interval = 600s)
    Test.moveTime(by: 600.0)
    
    // Verify still in gap (round ended, no draw started)
    let state = getPoolInitialState(poolID)
    Test.assertEqual(true, state["isRoundEnded"]! as! Bool)
    Test.assertEqual(UInt64(1), state["currentRoundID"]! as! UInt64) // Still round 1
    
    // New user can still deposit during extended gap
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Execute draw and verify gap user gets full entries in new round
    executeFullDraw(user, poolID: poolID)
    
    // Check gap user has entries in new round
    let entries = getUserEntries(gapUser.address, poolID)
    Test.assert(entries > 0.0, message: "Gap user should have entries after draw")
}

access(all) fun testVeryLongGapPeriod() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for a very long time (6000 seconds = 100x round duration)
    Test.moveTime(by: 6000.0)
    
    // System should still function - execute draw
    executeFullDraw(user, poolID: poolID)
    
    // Verify round transitioned
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
    
    // User should have won the prize (only participant)
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

access(all) fun testManyUsersJoinDuringGap() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 10.0
    
    // Setup initial user
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // Many users join during gap
    var gapUsers: [Test.TestAccount] = []
    var i = 0
    while i < 5 {
        let gapUser = Test.createAccount()
        setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
        depositToPool(gapUser, poolID: poolID, amount: depositAmount)
        gapUsers.append(gapUser)
        i = i + 1
    }
    
    // Execute draw
    executeFullDraw(existingUser, poolID: poolID)
    
    // Verify all gap users have entries in new round
    for gapUser in gapUsers {
        let entries = getUserEntries(gapUser.address, poolID)
        Test.assert(entries > 0.0, message: "Gap user should have entries after draw")
    }
}

// ============================================================================
// TESTS - Gap Period User-Specific Behavior
// ============================================================================

access(all) fun testNewUserOnlyInGap() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial user who will have entries in round 1
    let round1User = Test.createAccount()
    setupUserWithFundsAndCollection(round1User, amount: depositAmount + 10.0)
    depositToPool(round1User, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Gap-only user joins (never in round 1)
    let gapOnlyUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapOnlyUser, amount: depositAmount + 10.0)
    depositToPool(gapOnlyUser, poolID: poolID, amount: depositAmount)
    
    // Execute draw (round1User should be in pendingDrawRound, gapOnlyUser should get lazy fallback)
    executeFullDraw(round1User, poolID: poolID)
    
    // Verify gap-only user has entries in new round (via lazy fallback)
    let gapUserEntries = getUserEntries(gapOnlyUser.address, poolID)
    
    // Gap user should have ~full entries (deposited at start of new round effectively)
    let tolerance: UFix64 = 5.0
    let difference = gapUserEntries > depositAmount 
        ? gapUserEntries - depositAmount 
        : depositAmount - gapUserEntries
    
    Test.assert(
        difference < tolerance,
        message: "Gap-only user should get ~full entries in new round. Got: ".concat(gapUserEntries.toString())
    )
}

access(all) fun testExistingUserDepositsMoreInGap() {
    let poolID = createTestPoolWithMediumInterval()
    let initialDeposit: UFix64 = 100.0
    let additionalDeposit: UFix64 = 50.0
    
    // Setup user with initial deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: initialDeposit + additionalDeposit + 20.0)
    depositToPool(user, poolID: poolID, amount: initialDeposit)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end (enter gap period)
    Test.moveTime(by: 61.0)
    
    // User deposits more during gap
    depositToPool(user, poolID: poolID, amount: additionalDeposit)
    
    // Verify total balance
    let balance = getUserPoolBalance(user.address, poolID)
    let expectedBalance = initialDeposit + additionalDeposit
    let tolerance: UFix64 = 0.01
    let difference = balance["totalBalance"]! > expectedBalance 
        ? balance["totalBalance"]! - expectedBalance 
        : expectedBalance - balance["totalBalance"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should be ~150 after 100+50 deposits. Got: ".concat(balance["totalBalance"]!.toString())
    )
    
    // Execute draw
    executeFullDraw(user, poolID: poolID)
    
    // User should win (only participant) and have entries in new round
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

access(all) fun testGapDepositFinalizedCorrectly() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial user
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: depositAmount + 10.0)
    depositToPool(existingUser, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Gap user deposits (should trigger finalizeUserForGap in ended round)
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Execute full draw
    executeFullDraw(existingUser, poolID: poolID)
    
    // Both users should now be in round 2
    let existingUserEntries = getUserEntries(existingUser.address, poolID)
    let gapUserEntries = getUserEntries(gapUser.address, poolID)
    
    // Both should have entries (gap user via lazy fallback)
    Test.assert(existingUserEntries > 0.0, message: "Existing user should have entries")
    Test.assert(gapUserEntries > 0.0, message: "Gap user should have entries")
}

// ============================================================================
// TESTS - Gap Period with State Changes
// ============================================================================

access(all) fun testGapPeriodUserEntriesInEndedRound() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user and deposit at start
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Get entries BEFORE round ends (should be projected for full round)
    let entriesBeforeEnd = getUserEntries(user.address, poolID)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Get entries AFTER round ends but before draw (gap period)
    // Entries should still be calculated correctly
    let entriesInGap = getUserEntries(user.address, poolID)
    
    // Entries should be similar (both calculating projected TWAB)
    let tolerance: UFix64 = 5.0
    let difference = entriesBeforeEnd > entriesInGap 
        ? entriesBeforeEnd - entriesInGap 
        : entriesInGap - entriesBeforeEnd
    
    Test.assert(
        difference < tolerance,
        message: "Entries should be consistent before and during gap. Before: "
            .concat(entriesBeforeEnd.toString())
            .concat(", In gap: ").concat(entriesInGap.toString())
    )
}

access(all) fun testGapPeriodDoesNotAffectPriorRoundEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user at start of round
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Gap user joins during gap
    let gapUser = Test.createAccount()
    setupUserWithFundsAndCollection(gapUser, amount: depositAmount + 10.0)
    depositToPool(gapUser, poolID: poolID, amount: depositAmount)
    
    // Execute draw
    executeFullDraw(user, poolID: poolID)
    
    // The original user should have won (gapUser had 0 entries in round 1)
    let userPrizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, userPrizes["totalEarnedPrizes"]!)
    
    // Gap user should have 0 prizes (wasn't eligible in round 1)
    let gapUserPrizes = getUserPrizes(gapUser.address, poolID)
    Test.assertEqual(0.0, gapUserPrizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Gap Period Edge Cases
// ============================================================================

access(all) fun testImmediateDrawAfterRoundEnd() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait exactly for round to end (minimal gap - just past 60s)
    Test.moveTime(by: 61.0)
    
    // Execute draw immediately
    executeFullDraw(user, poolID: poolID)
    
    // Should work correctly
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

access(all) fun testMultipleGapDepositsFromSameUser() {
    let poolID = createTestPoolWithMediumInterval()
    let depositPerTx: UFix64 = 25.0
    
    // Setup initial user
    let existingUser = Test.createAccount()
    setupUserWithFundsAndCollection(existingUser, amount: 200.0)
    depositToPool(existingUser, poolID: poolID, amount: depositPerTx)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Multiple deposits from same user during gap
    depositToPool(existingUser, poolID: poolID, amount: depositPerTx)
    depositToPool(existingUser, poolID: poolID, amount: depositPerTx)
    depositToPool(existingUser, poolID: poolID, amount: depositPerTx)
    
    // Verify total balance
    let balance = getUserPoolBalance(existingUser.address, poolID)
    let expectedBalance = depositPerTx * 4.0 // 4 deposits of 25
    let tolerance: UFix64 = 0.01
    let difference = balance["totalBalance"]! > expectedBalance 
        ? balance["totalBalance"]! - expectedBalance 
        : expectedBalance - balance["totalBalance"]!
    
    Test.assert(
        difference < tolerance,
        message: "Balance should be 100 after 4x25 deposits. Got: ".concat(balance["totalBalance"]!.toString())
    )
}

access(all) fun testGapPeriodWithMultipleDepositsAndWithdrawals() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup initial user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 300.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Complex sequence during gap
    depositToPool(user, poolID: poolID, amount: 50.0)   // 150 total
    withdrawFromPool(user, poolID: poolID, amount: 30.0) // 120 total
    depositToPool(user, poolID: poolID, amount: 20.0)    // 140 total
    withdrawFromPool(user, poolID: poolID, amount: 40.0) // 100 total
    
    // Verify final balance
    let balance = getUserPoolBalance(user.address, poolID)
    let expectedBalance: UFix64 = 100.0
    let tolerance: UFix64 = 0.5
    let difference = balance["totalBalance"]! > expectedBalance 
        ? balance["totalBalance"]! - expectedBalance 
        : expectedBalance - balance["totalBalance"]!
    
    Test.assert(
        difference < tolerance,
        message: "Final balance should be ~100. Got: ".concat(balance["totalBalance"]!.toString())
    )
    
    // Execute draw
    executeFullDraw(user, poolID: poolID)
    
    // Verify prize won
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

