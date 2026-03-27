import Test
import "PrizeLinkedAccounts"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Adversarial Last-Second Deposit Scenarios
// ============================================================================

// Large last-second deposit: time is prorated, so the attacker cannot get ~1000 full-round entries.
// Entries are token-weighted via share conversion—after share price rises from yield, 1000 FLOW mints
// fewer shares, so prorated entries are often *below* the naive 1000×(2/60) token estimate (~33).
// Lottery outcome is not asserted—only that weight stays negligible vs raw capital.
access(all) fun testLastSecondDepositGetsNearZeroWeight() {
    let poolID = createTestPoolWithMediumInterval()

    // Honest user deposits at round start
    let honestUser = Test.createAccount()
    setupUserWithFundsAndCollection(honestUser, amount: DEFAULT_DEPOSIT_AMOUNT + 5.0)
    depositToPool(honestUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Advance to near end of round (58s of 60s)
    Test.moveTime(by: 58.0)

    // Attacker deposits 100x the honest user's amount with ~2 seconds left
    let attacker = Test.createAccount()
    setupUserWithFundsAndCollection(attacker, amount: 1005.0)
    depositToPool(attacker, poolID: poolID, amount: 1000.0)

    // Advance to end of round
    Test.moveTime(by: 2.0)

    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    // Snapshot at round end (before draw): startNextRound changes active round and invalidates
    // "just finished draw" entry comparisons if read after executeFullDraw.
    let honestEntries = getUserEntries(honestUser.address, poolID)
    let attackerEntries = getUserEntries(attacker.address, poolID)

    // Honest: ~10 token-weighted entries for full round
    let honestDiff = honestEntries > 10.0 ? honestEntries - 10.0 : 10.0 - honestEntries
    Test.assert(
        honestDiff < 2.0,
        message: "Honest entries should be ~10. Got: ".concat(honestEntries.toString())
    )

    // Attacker: non-trivial but far below 1000 (cannot buy a full round of weight with capital alone).
    Test.assert(
        attackerEntries > 1.0,
        message: "Attacker should have small prorated entries. Got: ".concat(attackerEntries.toString())
    )
    Test.assert(
        attackerEntries < 1000.0 * 0.05,
        message: "Late deposit must not approach full-round weight (<5% of naive 1000). Got: ".concat(attackerEntries.toString())
    )

    executeFullDraw(honestUser, poolID: poolID)
}

// Attacker with 50× capital and ~1s of hold gets less **entry weight** than honest full-round
// holder (~500/60 ≈ 8.3 vs ~10). Lottery winner is still random; we only assert TWAB/entries.
//
// Timing slack: jump to 58s (not 59s), deposit, then moveTime(1) before fundPrizePool. If the
// admin tx ran first after a t≈59 deposit, block time could pass targetEndTime and TWAB would
// cap at round end before the deposit timestamp—giving the attacker zero entries (flaky).
access(all) fun testLastSecondDepositCannotWinDespiteLargeCapital() {
    let poolID = createTestPoolWithMediumInterval()

    // Honest user deposits at round start
    let honestUser = Test.createAccount()
    setupUserWithFundsAndCollection(honestUser, amount: DEFAULT_DEPOSIT_AMOUNT + 5.0)
    depositToPool(honestUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // 58s into 60s round — leaves margin before attacker deposit + funding txs cross targetEndTime
    Test.moveTime(by: 58.0)

    // Attacker deposits 50x the honest user's amount with ~2s nominally left (1s of hold before snapshot)
    let attacker = Test.createAccount()
    setupUserWithFundsAndCollection(attacker, amount: 505.0)
    depositToPool(attacker, poolID: poolID, amount: 500.0)

    // One second of proration while still before round end; admin funding after this keeps lastUpdate < targetEndTime
    Test.moveTime(by: 1.0)

    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)

    let honestEntries = getUserEntries(honestUser.address, poolID)
    let attackerEntries = getUserEntries(attacker.address, poolID)

    // Slightly below 10 if queried before the clock hits targetEndTime (~59/60 of the round)
    let honestDiff = honestEntries > 10.0 ? honestEntries - 10.0 : 10.0 - honestEntries
    Test.assert(
        honestDiff < 2.0,
        message: "Honest entries should be ~10 (or ~9.8+ just before round end). Got: ".concat(honestEntries.toString())
    )

    // ~500 × (1/60) ≈ 8.33 in token-prorated terms (share price may reduce slightly)
    Test.assert(
        attackerEntries > 6.0 && attackerEntries < 11.0,
        message: "Attacker prorated entries should be ~8.3. Got: ".concat(attackerEntries.toString())
    )

    Test.assert(
        honestEntries > attackerEntries,
        message: "Honest should have higher entry weight. honest=".concat(honestEntries.toString()).concat(" attacker=").concat(attackerEntries.toString())
    )

    Test.moveTime(by: 1.0)
    executeFullDraw(honestUser, poolID: poolID)
}

// Directly compare TWAB entries: User A holds 50.0 for the full round,
// User B deposits 500.0 (10x) with only ~2 seconds left.
// User A's entries should dominate despite 10x less capital.
access(all) fun testDepositTwoSecondsBeforeDrawVsFullRoundHolder() {
    let poolID = createTestPoolWithMediumInterval()

    // User A deposits at round start
    let userA = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: 60.0)
    depositToPool(userA, poolID: poolID, amount: 50.0)

    // Advance to 58 seconds into 60-second round
    Test.moveTime(by: 58.0)

    // User B deposits 10x user A's amount with ~2 seconds left
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userB, amount: 510.0)
    depositToPool(userB, poolID: poolID, amount: 500.0)

    // Advance to end of round
    Test.moveTime(by: 2.0)

    // Capture entries before draw finalizes them
    let userAEntries = getUserEntries(userA.address, poolID)
    let userBEntries = getUserEntries(userB.address, poolID)

    // User A: ~50 × (58/60) ≈ 48.3 entries (tolerance 5.0 for tx timing)
    let userAExpected: UFix64 = 50.0
    let userATolerance: UFix64 = 5.0
    let userADiff = userAEntries > userAExpected ? userAEntries - userAExpected : userAExpected - userAEntries
    Test.assert(
        userADiff < userATolerance,
        message: "User A entries should be ~50. Got: ".concat(userAEntries.toString())
    )

    // User B: ~500 × (2/60) ≈ 16.7 entries — well below their 500.0 deposit
    Test.assert(
        userBEntries < 20.0,
        message: "User B entries should be < 20. Got: ".concat(userBEntries.toString())
    )

    // Honest user dominates despite 10x less capital
    Test.assert(
        userAEntries > userBEntries,
        message: "User A entries should exceed User B entries. A=".concat(userAEntries.toString()).concat(" B=").concat(userBEntries.toString())
    )
}

// Boundary test: at a 10x capital ratio with 5/60 of the round remaining,
// the attacker barely loses. Demonstrates the exact break-even point.
// User A: 10.0 × (55/60) ≈ 9.17 entries
// User B: 100.0 × (5/60) ≈ 8.33 entries
// Both have meaningful entries; User A still edges out User B.
access(all) fun testEarlyDepositAlwaysDominatesLateDeposit() {
    let poolID = createTestPoolWithMediumInterval()

    // User A deposits at round start
    let userA = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: 20.0)
    depositToPool(userA, poolID: poolID, amount: 10.0)

    // Advance to 55 seconds into 60-second round
    Test.moveTime(by: 55.0)

    // User B deposits 10x user A's amount with only 5 seconds left
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userB, amount: 110.0)
    depositToPool(userB, poolID: poolID, amount: 100.0)

    // Advance to end of round
    Test.moveTime(by: 5.0)

    let userAEntries = getUserEntries(userA.address, poolID)
    let userBEntries = getUserEntries(userB.address, poolID)

    // Both should have non-zero entries
    Test.assert(
        userAEntries > 0.0,
        message: "User A should have entries. Got: ".concat(userAEntries.toString())
    )
    Test.assert(
        userBEntries > 0.0,
        message: "User B should have entries. Got: ".concat(userBEntries.toString())
    )

    // User A edges out User B: 9.17 vs 8.33 (approximately)
    Test.assert(
        userAEntries > userBEntries,
        message: "User A entries should exceed User B entries at 10x capital / 5s boundary. A=".concat(userAEntries.toString()).concat(" B=").concat(userBEntries.toString())
    )
}
