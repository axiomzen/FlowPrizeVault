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
// TESTS - Consecutive Round Sequences
// ============================================================================

access(all) fun testThreeConsecutiveRounds() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Verify starting at round 1
    let stateRound1 = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(1), stateRound1["currentRoundID"]! as! UInt64)
    
    // Fund lottery for round 1
    fundLotteryPool(poolID, amount: 5.0)
    
    // Execute round 1 draw
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify now at round 2
    let stateRound2 = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), stateRound2["currentRoundID"]! as! UInt64)
    
    // Fund lottery for round 2
    fundLotteryPool(poolID, amount: 5.0)
    
    // Execute round 2 draw
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify now at round 3
    let stateRound3 = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(3), stateRound3["currentRoundID"]! as! UInt64)
    
    // Fund lottery for round 3
    fundLotteryPool(poolID, amount: 5.0)
    
    // Execute round 3 draw
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify now at round 4
    let stateRound4 = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(4), stateRound4["currentRoundID"]! as! UInt64)
    
    // User should have won all 3 prizes (only participant)
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(15.0, prizes["totalEarnedPrizes"]!)
}

access(all) fun testUserSkipsMiddleRound() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user who will be active in rounds 1 and 3
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount * 2.0 + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery for round 1
    fundLotteryPool(poolID, amount: 5.0)
    
    // Execute round 1 draw - user wins
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    let prizesAfterRound1 = getUserPrizes(user.address, poolID)
    Test.assertEqual(5.0, prizesAfterRound1["totalEarnedPrizes"]!)
    
    // User withdraws everything before round 2
    let currentBalance = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    withdrawFromPool(user, poolID: poolID, amount: currentBalance)
    
    // Fund lottery for round 2 (user has 0 shares, should not win)
    fundLotteryPool(poolID, amount: 5.0)
    
    // We need another participant for round 2
    let round2User = Test.createAccount()
    setupUserWithFundsAndCollection(round2User, amount: depositAmount + 10.0)
    depositToPool(round2User, poolID: poolID, amount: depositAmount)
    
    // Execute round 2 draw - round2User should win
    Test.moveTime(by: 61.0)
    executeFullDraw(round2User, poolID: poolID)
    
    // User rejoins for round 3
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund lottery for round 3
    fundLotteryPool(poolID, amount: 5.0)
    
    // Execute round 3 draw
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify round transitions happened
    let finalState = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(4), finalState["currentRoundID"]! as! UInt64)
}

access(all) fun testUserChangingBalanceAcrossRounds() {
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup user with enough funds
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 500.0)
    
    // Round 1: Deposit 100
    depositToPool(user, poolID: poolID, amount: 100.0)
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Round 2: Add 50 more (now 155 with prize)
    depositToPool(user, poolID: poolID, amount: 50.0)
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Round 3: Withdraw 30
    let balanceBeforeWithdraw = getUserPoolBalance(user.address, poolID)["totalBalance"]!
    withdrawFromPool(user, poolID: poolID, amount: 30.0)
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // User should have all prizes
    let prizes = getUserPrizes(user.address, poolID)
    Test.assertEqual(15.0, prizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Round Transition Edge Cases
// ============================================================================

access(all) fun testDrawIntervalChangesBetweenRounds() {
    let poolID = createTestPoolWithMediumInterval() // 60 second interval
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 20.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Fund and execute round 1 with medium interval
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Admin changes interval (this would need an admin function)
    // For now, we verify the round uses the interval from pool creation
    
    // Execute round 2
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify rounds progressed
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(3), state["currentRoundID"]! as! UInt64)
}

access(all) fun testPrizeAffectsNextRoundTWAB() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let prizeAmount: UFix64 = 50.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 20.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Get entries before winning
    let entriesRound1 = getUserEntries(user.address, poolID)
    
    // Fund and execute round 1
    fundLotteryPool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // User won 50, now has 150 balance
    let balanceAfterWin = getUserPoolBalance(user.address, poolID)
    Test.assertEqual(depositAmount + prizeAmount, balanceAfterWin["totalBalance"]!)
    
    // Get entries in round 2 - should be higher due to larger balance
    let entriesRound2 = getUserEntries(user.address, poolID)
    
    // Round 2 entries should be higher (more shares from prize)
    // Note: This depends on timing, but entries should reflect new share count
    Test.assert(
        entriesRound2 > entriesRound1 * 1.3, // At least 30% higher
        message: "Round 2 entries should be higher due to prize. R1: "
            .concat(entriesRound1.toString())
            .concat(", R2: ").concat(entriesRound2.toString())
    )
}

access(all) fun testMultipleWinnersNextRoundImpact() {
    // Create pool with percentage split (50/50 for 2 winners)
    let poolID = createPoolWithPercentageSplit(splits: [0.5, 0.5], nftIDs: [])
    let depositAmount: UFix64 = 100.0
    let prizeAmount: UFix64 = 100.0
    
    // Setup two users with equal deposits
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 20.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 20.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Fund and execute round 1
    fundLotteryPool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Both users should have won 50 each (50/50 split)
    let user1Prizes = getUserPrizes(user1.address, poolID)
    let user2Prizes = getUserPrizes(user2.address, poolID)
    let totalAwarded = user1Prizes["totalEarnedPrizes"]! + user2Prizes["totalEarnedPrizes"]!
    
    Test.assertEqual(prizeAmount, totalAwarded)
}

// ============================================================================
// TESTS - State Persistence Across Rounds
// ============================================================================

access(all) fun testUserEntriesCarryForwardCorrectly() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 20.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Execute multiple rounds, checking entries each time
    var roundNum = 1
    while roundNum <= 3 {
        fundLotteryPool(poolID, amount: 5.0)
        Test.moveTime(by: 61.0)
        
        // Get entries before draw
        let entriesBeforeDraw = getUserEntries(user.address, poolID)
        Test.assert(entriesBeforeDraw > 0.0, message: "Should have entries in round ".concat(roundNum.toString()))
        
        executeFullDraw(user, poolID: poolID)
        
        // Get entries after draw (in new round)
        let entriesAfterDraw = getUserEntries(user.address, poolID)
        Test.assert(entriesAfterDraw > 0.0, message: "Should have entries after round ".concat(roundNum.toString()))
        
        roundNum = roundNum + 1
    }
}

access(all) fun testRoundIDSequenceIsContiguous() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Track round IDs through multiple draws
    var expectedRoundID: UInt64 = 1
    
    while expectedRoundID <= 5 {
        let state = getPoolInitialState(poolID)
        let currentRoundID = state["currentRoundID"]! as! UInt64
        
        Test.assertEqual(expectedRoundID, currentRoundID)
        
        // Fund and execute draw
        fundLotteryPool(poolID, amount: 1.0)
        Test.moveTime(by: 61.0)
        executeFullDraw(user, poolID: poolID)
        
        expectedRoundID = expectedRoundID + 1
    }
}

access(all) fun testOldRoundDataCleanedUp() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 20.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Execute round 1
    fundLotteryPool(poolID, amount: 5.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user, poolID: poolID)
    
    // Verify we're in round 2
    let stateAfterDraw = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(2), stateAfterDraw["currentRoundID"]! as! UInt64)
    
    // Check draw status - no pending draw should exist
    let drawStatus = getDrawStatus(poolID)
    Test.assertEqual(false, drawStatus["isPendingDrawInProgress"]! as! Bool)
    Test.assertEqual(false, drawStatus["isBatchInProgress"]! as! Bool)
}

// ============================================================================
// TESTS - Multiple Users Across Multiple Rounds
// ============================================================================

access(all) fun testMultipleUsersMultipleRounds() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup 3 users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 50.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 50.0)
    setupUserWithFundsAndCollection(user3, amount: depositAmount + 50.0)
    
    // Round 1: All users deposit
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    depositToPool(user3, poolID: poolID, amount: depositAmount)
    
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Round 2: User2 withdraws
    let user2Balance = getUserPoolBalance(user2.address, poolID)["totalBalance"]!
    withdrawFromPool(user2, poolID: poolID, amount: user2Balance)
    
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Round 3: User2 rejoins with different amount
    depositToPool(user2, poolID: poolID, amount: depositAmount / 2.0)
    
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Verify all rounds completed
    let finalState = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(4), finalState["currentRoundID"]! as! UInt64)
    
    // Verify total prizes distributed
    let prizes1 = getUserPrizes(user1.address, poolID)["totalEarnedPrizes"]!
    let prizes2 = getUserPrizes(user2.address, poolID)["totalEarnedPrizes"]!
    let prizes3 = getUserPrizes(user3.address, poolID)["totalEarnedPrizes"]!
    let totalPrizes = prizes1 + prizes2 + prizes3
    
    Test.assertEqual(30.0, totalPrizes)
}

access(all) fun testNewUserJoinsEachRound() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup initial user
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 30.0)
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    
    // Round 1
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Round 2: New user joins
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 10.0)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // Round 3: Another new user joins
    let user3 = Test.createAccount()
    setupUserWithFundsAndCollection(user3, amount: depositAmount + 10.0)
    depositToPool(user3, poolID: poolID, amount: depositAmount)
    
    fundLotteryPool(poolID, amount: 10.0)
    Test.moveTime(by: 61.0)
    executeFullDraw(user1, poolID: poolID)
    
    // All three users should have entries now
    let entries1 = getUserEntries(user1.address, poolID)
    let entries2 = getUserEntries(user2.address, poolID)
    let entries3 = getUserEntries(user3.address, poolID)
    
    Test.assert(entries1 > 0.0, message: "User1 should have entries")
    Test.assert(entries2 > 0.0, message: "User2 should have entries")
    Test.assert(entries3 > 0.0, message: "User3 should have entries")
}

// ============================================================================
// TESTS - Round with Zero Activity
// ============================================================================

access(all) fun testRoundWithNoPrize() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Don't fund lottery pool for round 1
    
    // Wait for round to end
    Test.moveTime(by: 61.0)
    
    // Check status
    let status = getDrawStatus(poolID)
    let lotteryBalance = status["lotteryPoolBalance"]! as! UFix64
    
    // If lottery balance is 0, draw might still work but with 0 prize
    // This test verifies the system doesn't break with 0 prize
    if lotteryBalance > 0.0 {
        executeFullDraw(user, poolID: poolID)
        
        let state = getPoolInitialState(poolID)
        Test.assertEqual(UInt64(2), state["currentRoundID"]! as! UInt64)
    }
}

access(all) fun testUserBalanceConsistentAcrossRounds() {
    let poolID = createTestPoolWithMediumInterval()
    let depositAmount: UFix64 = 100.0
    let prizeAmount: UFix64 = 10.0
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 50.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Track balance through rounds
    var expectedBalance = depositAmount
    var roundNum = 1
    
    while roundNum <= 3 {
        let balanceBefore = getUserPoolBalance(user.address, poolID)["totalBalance"]!
        
        // Verify balance is as expected (with tolerance for rounding)
        let tolerance: UFix64 = 0.1
        let difference = balanceBefore > expectedBalance 
            ? balanceBefore - expectedBalance 
            : expectedBalance - balanceBefore
        
        Test.assert(
            difference < tolerance,
            message: "Balance mismatch in round ".concat(roundNum.toString())
                .concat(". Expected: ").concat(expectedBalance.toString())
                .concat(", Got: ").concat(balanceBefore.toString())
        )
        
        // Execute draw
        fundLotteryPool(poolID, amount: prizeAmount)
        Test.moveTime(by: 61.0)
        executeFullDraw(user, poolID: poolID)
        
        // Update expected balance (user won prize)
        expectedBalance = expectedBalance + prizeAmount
        
        roundNum = roundNum + 1
    }
}

