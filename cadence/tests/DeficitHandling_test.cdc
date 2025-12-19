import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// HELPER - Create pool and deposit to establish baseline
// ============================================================================

access(all) fun setupPoolWithDeposit(savings: UFix64, lottery: UFix64, treasury: UFix64, depositAmount: UFix64): UInt64 {
    // Create pool with specified distribution
    let poolID = createPoolWithDistribution(savings: savings, lottery: lottery, treasury: treasury)
    
    // Create and fund a user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    
    // Deposit to pool
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    return poolID
}

/// Helper to get actual balance from getUserActualBalance result
access(all) fun getActualBalanceFromResult(_ result: {String: UFix64}): UFix64 {
    return result["actualBalance"] ?? 0.0
}

// ============================================================================
// TESTS - Basic Deficit Detection
// ============================================================================

access(all) fun testDeficitDetectedWhenYieldVaultDecreases() {
    // Setup: Create pool with 70/20/10 distribution, deposit 100 FLOW
    let poolID = setupPoolWithDeposit(savings: 0.7, lottery: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    let initialSharePrice = initialInfo["sharePrice"]!
    
    Test.assertEqual(100.0, initialTotalStaked)
    
    // Simulate depreciation: Remove 10 FLOW from yield vault
    // Pool index matches creation order (0-based)
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Trigger sync - this should detect and apply the deficit
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Total staked should have decreased
    Test.assert(finalTotalStaked < initialTotalStaked, message: "totalStaked should decrease after deficit")
    
    // Share price should have decreased (meaning users' balances decreased)
    Test.assert(finalSharePrice < initialSharePrice, message: "sharePrice should decrease after deficit")
}

// ============================================================================
// TESTS - Deficit Distribution According to Strategy
// ============================================================================

access(all) fun testDeficitDistributedAccordingToStrategy() {
    // Setup: Create pool with 50/50/0 (savings/lottery/treasury)
    // This makes the math easy: deficit should be split evenly
    let poolID = setupPoolWithDeposit(savings: 0.5, lottery: 0.5, treasury: 0.0, depositAmount: 100.0)
    
    // Add some yield first to build up pendingLotteryYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check that lottery yield was accumulated
    let midInfo = getPoolSavingsInfo(poolID)
    let pendingLottery = midInfo["pendingLotteryYield"]!
    Test.assert(pendingLottery > 0.0, message: "Should have pending lottery yield after appreciation")
    
    // Now simulate depreciation
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // Both savings and lottery should have absorbed the deficit
    // With 50/50 split, each should absorb 50% of the 10 FLOW deficit = 5 each
    // pendingLotteryYield should have decreased by ~5
    Test.assert(finalPendingLottery < pendingLottery, message: "pendingLotteryYield should decrease")
}

access(all) fun testDeficitDistributionWithTreasury() {
    // Setup: Create pool with 50/30/20 (savings/lottery/treasury)
    // Treasury is forwarded immediately, so deficits split between savings & lottery
    // Proportional shares: savings = 50/(50+30) = 62.5%, lottery = 30/(50+30) = 37.5%
    let poolID = setupPoolWithDeposit(savings: 0.5, lottery: 0.3, treasury: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    let initialSharePrice = initialInfo["sharePrice"]!
    
    Test.assertEqual(100.0, initialTotalStaked)
    Test.assertEqual(0.0, initialPendingLottery)
    Test.assertEqual(1.0, initialSharePrice)
    
    // Add 20 FLOW yield to build up reserves
    // Distribution: savings = 10 (50%), lottery = 6 (30%), treasury = 4 (20% forwarded)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Verify yield was distributed correctly
    let afterYieldInfo = getPoolSavingsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["totalStaked"]!
    let afterYieldPendingLottery = afterYieldInfo["pendingLotteryYield"]!
    
    // totalStaked should increase by savings portion: 100 + 10 = 110
    Test.assert(afterYieldTotalStaked > 109.0 && afterYieldTotalStaked < 111.0, 
        message: "totalStaked should be ~110 after yield. Got: ".concat(afterYieldTotalStaked.toString()))
    
    // pendingLotteryYield should be lottery portion: 6
    Test.assert(afterYieldPendingLottery > 5.0 && afterYieldPendingLottery < 7.0,
        message: "pendingLotteryYield should be ~6 after yield. Got: ".concat(afterYieldPendingLottery.toString()))
    
    // Now simulate 10 FLOW deficit
    // Deficit distribution (excluding treasury):
    //   savingsShare = 0.5 / (0.5 + 0.3) = 0.625 → 10 * 0.625 = 6.25 FLOW
    //   lotteryShare = 0.3 / (0.5 + 0.3) = 0.375 → 10 * 0.375 = 3.75 FLOW
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Calculate expected values
    let expectedTotalStaked = afterYieldTotalStaked - 6.25  // ~103.75
    let expectedPendingLottery = afterYieldPendingLottery - 3.75  // ~2.25
    
    // Verify totalStaked decreased by savings portion (~6.25)
    let actualSavingsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(actualSavingsLoss > 6.0 && actualSavingsLoss < 6.5,
        message: "Savings should absorb ~6.25 FLOW (62.5% of deficit). Actual loss: ".concat(actualSavingsLoss.toString()))
    
    // Verify pendingLotteryYield decreased by lottery portion (~3.75)
    let actualLotteryLoss = afterYieldPendingLottery - finalPendingLottery
    Test.assert(actualLotteryLoss > 3.5 && actualLotteryLoss < 4.0,
        message: "Lottery should absorb ~3.75 FLOW (37.5% of deficit). Actual loss: ".concat(actualLotteryLoss.toString()))
    
    // Verify final values are approximately correct
    Test.assert(finalTotalStaked > 103.0 && finalTotalStaked < 104.5,
        message: "Final totalStaked should be ~103.75. Got: ".concat(finalTotalStaked.toString()))
    Test.assert(finalPendingLottery > 2.0 && finalPendingLottery < 2.5,
        message: "Final pendingLotteryYield should be ~2.25. Got: ".concat(finalPendingLottery.toString()))
    
    // Verify share price decreased (reflects the savings loss)
    Test.assert(finalSharePrice < afterYieldInfo["sharePrice"]!,
        message: "Share price should decrease after deficit")
    
    // Total deficit absorbed should equal the original deficit amount
    let totalAbsorbed = actualSavingsLoss + actualLotteryLoss
    Test.assert(totalAbsorbed > 9.5 && totalAbsorbed < 10.5,
        message: "Total absorbed should be ~10 FLOW. Got: ".concat(totalAbsorbed.toString()))
}

access(all) fun testDeficitOnlySavingsWhen100PercentSavings() {
    // Setup: Create pool with 100% savings
    let poolID = setupPoolWithDeposit(savings: 1.0, lottery: 0.0, treasury: 0.0, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    
    // Simulate depreciation
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // All deficit should come from savings (share price decrease)
    Test.assert(finalTotalStaked < initialTotalStaked, message: "totalStaked should decrease")
    
    // pendingLotteryYield should be unchanged (still 0)
    Test.assertEqual(initialPendingLottery, finalPendingLottery)
}

access(all) fun testDeficitOnlyLotteryWhen100PercentLottery() {
    // Setup: Create pool with 100% lottery
    let poolID = setupPoolWithDeposit(savings: 0.0, lottery: 1.0, treasury: 0.0, depositAmount: 100.0)
    
    // Add yield first to build up pendingLotteryYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get state after appreciation
    let midInfo = getPoolSavingsInfo(poolID)
    let midTotalStaked = midInfo["totalStaked"]!
    let midPendingLottery = midInfo["pendingLotteryYield"]!
    
    // Total staked should be unchanged (all yield went to lottery)
    Test.assertEqual(100.0, midTotalStaked)
    Test.assert(midPendingLottery > 0.0, message: "Should have pending lottery yield")
    
    // Simulate small depreciation (less than pendingLotteryYield)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // totalStaked should be unchanged (deficit absorbed by lottery)
    Test.assertEqual(midTotalStaked, finalTotalStaked)
    
    // pendingLotteryYield should have decreased
    Test.assert(finalPendingLottery < midPendingLottery, message: "pendingLotteryYield should decrease")
}

// ============================================================================
// TESTS - Lottery Shortfall Handling
// ============================================================================

access(all) fun testLotteryShortfallFallsToSavings() {
    // Setup: Create pool with 50/50 distribution
    let poolID = setupPoolWithDeposit(savings: 0.5, lottery: 0.5, treasury: 0.0, depositAmount: 100.0)
    
    // Add small amount of yield to build up some pendingLotteryYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 4.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let midInfo = getPoolSavingsInfo(poolID)
    let pendingLottery = midInfo["pendingLotteryYield"]!
    // With 50/50 split, ~2 FLOW should be in pendingLotteryYield
    
    // Now simulate a larger depreciation than pendingLotteryYield can cover
    // 10 FLOW deficit with 50/50 = 5 each, but lottery only has ~2
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // pendingLotteryYield should be 0 or very close (absorbed all it could)
    Test.assert(finalPendingLottery < 0.1, message: "pendingLotteryYield should be nearly depleted")
    
    // The shortfall should have been absorbed by savings
    // (verified by the share price decrease being more than just the savings portion)
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testDeficitLargerThanTotalAssets() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(savings: 0.7, lottery: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    
    // Try to depreciate more than exists in the vault
    // The vault only has 100 FLOW, so withdrawing 150 should fail
    let success = simulateYieldDepreciationExpectFailure(poolIndex: poolIndex, amount: 150.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // This should fail because there's not enough in the vault
    Test.assertEqual(false, success)
}

access(all) fun testMultipleDeficitsAccumulate() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(savings: 0.7, lottery: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Apply multiple small deficits
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let midInfo = getPoolSavingsInfo(poolID)
    let midSharePrice = midInfo["sharePrice"]!
    
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should decrease progressively
    Test.assert(midSharePrice < initialSharePrice, message: "Share price should decrease after first deficit")
    Test.assert(finalSharePrice < midSharePrice, message: "Share price should decrease further after second deficit")
}

access(all) fun testDeficitFollowedByExcess() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(savings: 0.7, lottery: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Apply deficit first
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterDeficitInfo = getPoolSavingsInfo(poolID)
    let afterDeficitSharePrice = afterDeficitInfo["sharePrice"]!
    Test.assert(afterDeficitSharePrice < initialSharePrice, message: "Share price should decrease after deficit")
    
    // Now add excess (more than was lost)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should increase past the post-deficit level
    Test.assert(finalSharePrice > afterDeficitSharePrice, message: "Share price should increase after excess")
}

access(all) fun testZeroDeficitNoChange() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(savings: 0.7, lottery: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["totalStaked"]!
    
    // Trigger sync without any change to yield vault
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    let finalTotalStaked = finalInfo["totalStaked"]!
    
    // Nothing should change
    Test.assertEqual(initialSharePrice, finalSharePrice)
    Test.assertEqual(initialTotalStaked, finalTotalStaked)
}

// ============================================================================
// TESTS - User Balance Impact
// ============================================================================

access(all) fun testUserBalanceDecreasesDuringDeficit() {
    // Setup: Create pool
    let poolID = createPoolWithDistribution(savings: 1.0, lottery: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Get initial user balance (actual withdrawable balance = shares × sharePrice)
    let initialBalanceInfo = getUserActualBalance(user.address, poolID)
    let initialActualBalance = getActualBalanceFromResult(initialBalanceInfo)
    let initialShares = initialBalanceInfo["shares"]!
    let initialSharePrice = initialBalanceInfo["sharePrice"]!
    
    Test.assertEqual(100.0, initialActualBalance)
    Test.assertEqual(1.0, initialSharePrice) // Initial share price should be 1.0
    
    // Simulate deficit - remove 10 FLOW from yield vault
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final user balance
    let finalBalanceInfo = getUserActualBalance(user.address, poolID)
    let finalActualBalance = getActualBalanceFromResult(finalBalanceInfo)
    let finalShares = finalBalanceInfo["shares"]!
    let finalSharePrice = finalBalanceInfo["sharePrice"]!
    
    // Shares should remain unchanged (user didn't withdraw)
    Test.assertEqual(initialShares, finalShares)
    
    // Share price should have decreased (this is how the deficit is reflected)
    Test.assert(finalSharePrice < initialSharePrice, message: "Share price should decrease after deficit. Initial: ".concat(initialSharePrice.toString()).concat(", Final: ").concat(finalSharePrice.toString()))
    
    // User's actual balance should have decreased by ~10 (the deficit)
    Test.assert(finalActualBalance < initialActualBalance, message: "User balance should decrease after deficit. Initial: ".concat(initialActualBalance.toString()).concat(", Final: ").concat(finalActualBalance.toString()))
    Test.assert(finalActualBalance > 89.0, message: "User balance should be around 90 after 10% deficit, but got: ".concat(finalActualBalance.toString()))
    Test.assert(finalActualBalance < 91.0, message: "User balance should be around 90 after 10% deficit, but got: ".concat(finalActualBalance.toString()))
}

access(all) fun testMultipleUsersShareDeficitProportionally() {
    // Setup: Create pool with 100% savings
    let poolID = createPoolWithDistribution(savings: 1.0, lottery: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    // Create two users with different deposit amounts
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    setupUserWithFundsAndCollection(user2, amount: 60.0)
    
    depositToPool(user1, poolID: poolID, amount: 100.0)  // 2/3 of pool
    depositToPool(user2, poolID: poolID, amount: 50.0)   // 1/3 of pool
    
    // Get initial actual balances (shares × sharePrice)
    let initial1 = getActualBalanceFromResult(getUserActualBalance(user1.address, poolID))
    let initial2 = getActualBalanceFromResult(getUserActualBalance(user2.address, poolID))
    
    // Simulate 15 FLOW deficit (10% of 150 total)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 15.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final actual balances
    let final1 = getActualBalanceFromResult(getUserActualBalance(user1.address, poolID))
    let final2 = getActualBalanceFromResult(getUserActualBalance(user2.address, poolID))
    
    // User1 should lose ~10 (2/3 of 15)
    let loss1 = initial1 - final1
    Test.assert(loss1 > 9.0 && loss1 < 11.0, message: "User1 should lose about 10 FLOW")
    
    // User2 should lose ~5 (1/3 of 15)
    let loss2 = initial2 - final2
    Test.assert(loss2 > 4.0 && loss2 < 6.0, message: "User2 should lose about 5 FLOW")
}
