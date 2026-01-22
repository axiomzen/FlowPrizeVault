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
// TESTS - Basic Entry Calculation
// ============================================================================
// Note: Medium interval pool uses 60 second draw interval

access(all) fun testEntriesReturnValidAmount() {
    // Create a pool with medium interval (60s) for stable testing
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Get entries - should be a positive number
    let entries = getUserEntries(user.address, poolID)
    
    Test.assert(entries > 0.0, message: "Entries should be positive after deposit")
    Test.assert(entries <= depositAmount, message: "Entries should not exceed deposit amount")
}

access(all) fun testEntriesAreHumanReadable() {
    // Entries should be in a reasonable range (not balance-seconds which would be huge)
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 50.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Wait for full draw interval to pass (60s + buffer)
    Test.moveTime(by: 61.0)
    
    let entries = getUserEntries(user.address, poolID)
    
    // After full interval, entries should equal deposit amount
    // Allow small tolerance for floating point
    let tolerance: UFix64 = 1.0
    let difference = entries > depositAmount ? entries - depositAmount : depositAmount - entries
    
    Test.assert(
        difference < tolerance,
        message: "After full interval, entries (".concat(entries.toString()).concat(") should equal deposit (").concat(depositAmount.toString()).concat(")")
    )
}

access(all) fun testZeroEntriesForNonDepositor() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup user but don't deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 10.0)
    
    let entries = getUserEntries(user.address, poolID)
    
    Test.assertEqual(0.0, entries)
}

// // ============================================================================
// // TESTS - Prorated Entries Based on Time
// // ============================================================================

access(all) fun testLateDepositGetsProportionalEntries() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // First user deposits at start
    let earlyUser = Test.createAccount()
    setupUserWithFundsAndCollection(earlyUser, amount: depositAmount + 10.0)
    depositToPool(earlyUser, poolID: poolID, amount: depositAmount)
    
    // Advance time halfway through interval (30s of 60s)
    Test.moveTime(by: 30.0)
    
    // Second user deposits halfway through
    let lateUser = Test.createAccount()
    setupUserWithFundsAndCollection(lateUser, amount: depositAmount + 10.0)
    depositToPool(lateUser, poolID: poolID, amount: depositAmount)
    
    // Advance to end of interval (another 30s)
    Test.moveTime(by: 30.0)
    
    // Get entries for both users
    let earlyEntries = getUserEntries(earlyUser.address, poolID)
    let lateEntries = getUserEntries(lateUser.address, poolID)
    
    // Early user should have ~100 entries (full interval)
    // Late user should have ~50 entries (half interval)
    let earlyTolerance: UFix64 = 5.0
    let earlyDiff = earlyEntries > depositAmount ? earlyEntries - depositAmount : depositAmount - earlyEntries
    Test.assert(
        earlyDiff < earlyTolerance,
        message: "Early depositor should have ~100 entries, got: ".concat(earlyEntries.toString())
    )
    
    // Late user should have roughly half
    let expectedLateEntries: UFix64 = 50.0
    let lateTolerance: UFix64 = 10.0  // Allow tolerance for timing variations
    let lateDiff = lateEntries > expectedLateEntries ? lateEntries - expectedLateEntries : expectedLateEntries - lateEntries
    Test.assert(
        lateDiff < lateTolerance,
        message: "Late depositor should have ~50 entries, got: ".concat(lateEntries.toString())
    )
    
    // Early user should have more entries than late user
    Test.assert(
        earlyEntries > lateEntries,
        message: "Early depositor should have more entries than late depositor"
    )
}

// // ============================================================================
// // TESTS - Entries Change with Deposits and Withdrawals
// // ============================================================================

access(all) fun testEntriesIncreaseWithAdditionalDeposit() {
    let poolID = createTestPoolWithMediumInterval()
    let initialDeposit: UFix64 = 50.0
    let additionalDeposit: UFix64 = 50.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: initialDeposit + additionalDeposit + 10.0)
    
    // First deposit
    depositToPool(user, poolID: poolID, amount: initialDeposit)
    
    // Wait for some time (30s of 60s interval)
    Test.moveTime(by: 30.0)
    
    let entriesAfterFirst = getUserEntries(user.address, poolID)
    
    // Second deposit
    depositToPool(user, poolID: poolID, amount: additionalDeposit)
    
    // Get entries immediately after second deposit
    let entriesAfterSecond = getUserEntries(user.address, poolID)
    
    // Entries should have increased (due to higher balance for remaining time)
    Test.assert(
        entriesAfterSecond > entriesAfterFirst,
        message: "Entries should increase after additional deposit. Before: ".concat(entriesAfterFirst.toString()).concat(", After: ").concat(entriesAfterSecond.toString())
    )
}

access(all) fun testEntriesDecreaseWithWithdrawal() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let withdrawAmount: UFix64 = 50.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Wait for half the interval (30s of 60s)
    Test.moveTime(by: 30.0)
    
    let entriesBeforeWithdraw = getUserEntries(user.address, poolID)
    
    // Withdraw half
    withdrawFromPool(user, poolID: poolID, amount: withdrawAmount)
    
    // Get entries immediately after withdrawal
    let entriesAfterWithdraw = getUserEntries(user.address, poolID)
    
    // Entries should have decreased
    Test.assert(
        entriesAfterWithdraw < entriesBeforeWithdraw,
        message: "Entries should decrease after withdrawal. Before: ".concat(entriesBeforeWithdraw.toString()).concat(", After: ").concat(entriesAfterWithdraw.toString())
    )
}

access(all) fun testEntriesDecreaseButRemainAfterFullWithdrawal() {
    // Entries are based on TWAB (Time-Weighted Average Balance).
    // Even after withdrawal, the user retains entries from their historical contribution.
    // If deposited for half the interval, they should have ~50% of their entries remaining.
    
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Wait for half the interval (30s of 60s)
    Test.moveTime(by: 30.0)
    
    // Verify we have entries before withdrawal
    let entriesBefore = getUserEntries(user.address, poolID)
    Test.assert(entriesBefore > 0.0, message: "Should have entries before withdrawal")
    
    // Withdraw everything
    withdrawFromPool(user, poolID: poolID, amount: depositAmount)
    
    // Entries should NOT be zero - user still has TWAB from time deposited
    let entriesAfter = getUserEntries(user.address, poolID)
    
    // Entries should still be positive (historical contribution preserved)
    Test.assert(
        entriesAfter > 0.0,
        message: "Entries should remain positive after withdrawal due to TWAB. Got: ".concat(entriesAfter.toString())
    )
    
    // Entries should have decreased (no more future accumulation)
    Test.assert(
        entriesAfter < entriesBefore,
        message: "Entries should decrease after withdrawal. Before: ".concat(entriesBefore.toString()).concat(", After: ").concat(entriesAfter.toString())
    )
    
    // After withdrawing at halfway point, entries should be approximately half
    // (100 balance * 30s) / 60s interval = 50 entries
    let expectedEntries: UFix64 = 50.0
    let tolerance: UFix64 = 5.0
    let difference = entriesAfter > expectedEntries ? entriesAfter - expectedEntries : expectedEntries - entriesAfter
    Test.assert(
        difference < tolerance,
        message: "After withdrawing at halfway, entries should be ~50, got: ".concat(entriesAfter.toString())
    )
}

// // ============================================================================
// // TESTS - Draw Progress
// // ============================================================================

access(all) fun testDrawProgressStartsLow() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Immediately after pool creation, progress should be low
    let progress = getDrawProgress(poolID)
    let drawProgress = progress["drawProgress"]!
    
    // Should be less than 50% at start
    Test.assert(drawProgress < 0.5, message: "Draw progress should be low at start, got: ".concat(drawProgress.toString()))
}

access(all) fun testDrawProgressIncreasesOverTime() {
    let poolID = createTestPoolWithMediumInterval()
    
    let progressAtStart = getDrawProgress(poolID)["drawProgress"]!
    
    // Advance time by half the interval (30s of 60s)
    Test.moveTime(by: 30.0)
    
    let progressMidway = getDrawProgress(poolID)["drawProgress"]!
    
    Test.assert(
        progressMidway > progressAtStart,
        message: "Draw progress should increase over time. Start: ".concat(progressAtStart.toString()).concat(", Midway: ").concat(progressMidway.toString())
    )
}

access(all) fun testTimeUntilDrawDecreases() {
    let poolID = createTestPoolWithMediumInterval()
    
    let timeAtStart = getDrawProgress(poolID)["timeUntilDraw"]!
    
    // Advance time (30s of 60s)
    Test.moveTime(by: 30.0)
    
    let timeMidway = getDrawProgress(poolID)["timeUntilDraw"]!
    
    Test.assert(
        timeMidway < timeAtStart,
        message: "Time until draw should decrease over time. Start: ".concat(timeAtStart.toString()).concat(", Midway: ").concat(timeMidway.toString())
    )
}
