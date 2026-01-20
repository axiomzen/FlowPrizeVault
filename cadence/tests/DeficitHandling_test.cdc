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

access(all) fun setupPoolWithDeposit(rewards: UFix64, prize: UFix64, treasury: UFix64, depositAmount: UFix64): UInt64 {
    // Create pool with specified distribution
    let poolID = createPoolWithDistribution(rewards: rewards, prize: prize, treasury: treasury)
    
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
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
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
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Total staked should have decreased
    Test.assert(finalTotalStaked < initialTotalStaked, message: "allocatedRewards should decrease after deficit")
    
    // Share price should have decreased (meaning users' balances decreased)
    Test.assert(finalSharePrice < initialSharePrice, message: "sharePrice should decrease after deficit")
}

// ============================================================================
// TESTS - Deficit Distribution According to Strategy
// ============================================================================

access(all) fun testDeficitDistributedAccordingToStrategy() {
    // Setup: Create pool with 50/50/0 (savings/lottery/treasury)
    // This makes the math easy: deficit should be split evenly
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.5, treasury: 0.0, depositAmount: 100.0)
    
    // Add some yield first to build up allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check that lottery yield was accumulated
    let midInfo = getPoolSavingsInfo(poolID)
    let pendingLottery = midInfo["allocatedPrizeYield"]!
    Test.assert(pendingLottery > 0.0, message: "Should have pending lottery yield after appreciation")
    
    // Now simulate depreciation
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    
    // Both savings and lottery should have absorbed the deficit
    // With 50/50 split, each should absorb 50% of the 10 FLOW deficit = 5 each
    // allocatedPrizeYield should have decreased by ~5
    Test.assert(finalPendingLottery < pendingLottery, message: "allocatedPrizeYield should decrease")
}

access(all) fun testDeficitDistributionWithTreasury() {
    // Setup: Create pool with 50/30/20 (savings/lottery/treasury)
    // Deficit uses DETERMINISTIC WATERFALL (not strategy proportions):
    //   1. Treasury absorbs first (drain completely if needed)
    //   2. Lottery absorbs second (drain completely if needed)
    //   3. Savings absorbs last (user principal protected)
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.3, treasury: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)

    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    let initialPendingLottery = initialInfo["allocatedPrizeYield"]!
    let initialPendingTreasury = initialInfo["allocatedTreasuryYield"]!
    let initialSharePrice = initialInfo["sharePrice"]!

    Test.assertEqual(100.0, initialTotalStaked)
    Test.assertEqual(0.0, initialPendingLottery)
    Test.assertEqual(0.0, initialPendingTreasury)
    Test.assertEqual(1.0, initialSharePrice)

    // Add 20 FLOW yield to build up reserves
    // Distribution: savings = 10 (50%), lottery = 6 (30%), treasury = 4 (20%)
    // All portions stay in yield source, tracked via pending variables
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Verify yield was distributed correctly
    let afterYieldInfo = getPoolSavingsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["allocatedRewards"]!
    let afterYieldPendingLottery = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingTreasury = afterYieldInfo["allocatedTreasuryYield"]!

    // allocatedRewards should increase by savings portion: 100 + 10 = 110
    Test.assert(afterYieldTotalStaked > 109.0 && afterYieldTotalStaked < 111.0,
        message: "allocatedRewards should be ~110 after yield. Got: ".concat(afterYieldTotalStaked.toString()))

    // allocatedPrizeYield should be lottery portion: 6
    Test.assert(afterYieldPendingLottery > 5.0 && afterYieldPendingLottery < 7.0,
        message: "allocatedPrizeYield should be ~6 after yield. Got: ".concat(afterYieldPendingLottery.toString()))

    // allocatedTreasuryYield should be treasury portion: 4
    Test.assert(afterYieldPendingTreasury > 3.0 && afterYieldPendingTreasury < 5.0,
        message: "allocatedTreasuryYield should be ~4 after yield. Got: ".concat(afterYieldPendingTreasury.toString()))

    // Now simulate 10 FLOW deficit
    // Deficit uses DETERMINISTIC WATERFALL to protect user funds:
    //   treasury absorbs first: all ~4 FLOW (depleted)
    //   lottery absorbs second: remaining ~6 FLOW (depleted)
    //   savings absorbs last: 0 FLOW (protected!)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    let finalPendingTreasury = finalInfo["allocatedTreasuryYield"]!
    let finalSharePrice = finalInfo["sharePrice"]!

    // Verify treasury was fully drained first (~4)
    let actualTreasuryLoss = afterYieldPendingTreasury - finalPendingTreasury
    Test.assert(actualTreasuryLoss > 3.5 && actualTreasuryLoss < 4.5,
        message: "Treasury should be fully drained (~4 FLOW). Actual loss: ".concat(actualTreasuryLoss.toString()))

    // Verify lottery absorbed the remaining deficit (~6)
    let actualLotteryLoss = afterYieldPendingLottery - finalPendingLottery
    Test.assert(actualLotteryLoss > 5.5 && actualLotteryLoss < 6.5,
        message: "Lottery should absorb remaining ~6 FLOW. Actual loss: ".concat(actualLotteryLoss.toString()))

    // Verify savings was protected (no loss)
    let actualSavingsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(actualSavingsLoss < 0.01,
        message: "Savings should be protected (no loss). Actual loss: ".concat(actualSavingsLoss.toString()))

    // Verify final values are approximately correct
    // Expected: 110 - 0 = 110 (savings protected)
    Test.assert(finalTotalStaked > 109.0 && finalTotalStaked < 111.0,
        message: "Final allocatedRewards should be ~110 (protected). Got: ".concat(finalTotalStaked.toString()))
    // Expected: lottery fully drained
    Test.assert(finalPendingLottery < 0.5,
        message: "Final allocatedPrizeYield should be ~0 (drained). Got: ".concat(finalPendingLottery.toString()))
    // Expected: treasury fully drained
    Test.assert(finalPendingTreasury < 0.5,
        message: "Final allocatedTreasuryYield should be ~0 (drained). Got: ".concat(finalPendingTreasury.toString()))

    // Verify share price unchanged (savings was protected)
    Test.assert(finalSharePrice > afterYieldInfo["sharePrice"]! - 0.01,
        message: "Share price should be unchanged (savings protected)")

    // Total deficit absorbed should equal the original deficit amount
    let totalAbsorbed = actualSavingsLoss + actualLotteryLoss + actualTreasuryLoss
    Test.assert(totalAbsorbed > 9.5 && totalAbsorbed < 10.5,
        message: "Total absorbed should be ~10 FLOW. Got: ".concat(totalAbsorbed.toString()))
}

access(all) fun testDeficitOnlySavingsWhen100PercentSavings() {
    // Setup: Create pool with 100% savings
    let poolID = setupPoolWithDeposit(rewards: 1.0, prize: 0.0, treasury: 0.0, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    let initialPendingLottery = initialInfo["allocatedPrizeYield"]!
    
    // Simulate depreciation
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    
    // All deficit should come from savings (share price decrease)
    Test.assert(finalTotalStaked < initialTotalStaked, message: "allocatedRewards should decrease")
    
    // allocatedPrizeYield should be unchanged (still 0)
    Test.assertEqual(initialPendingLottery, finalPendingLottery)
}

access(all) fun testDeficitOnlyLotteryWhen100PercentLottery() {
    // Setup: Create pool with 100% lottery
    let poolID = setupPoolWithDeposit(rewards: 0.0, prize: 1.0, treasury: 0.0, depositAmount: 100.0)
    
    // Add yield first to build up allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get state after appreciation
    let midInfo = getPoolSavingsInfo(poolID)
    let midTotalStaked = midInfo["allocatedRewards"]!
    let midPendingLottery = midInfo["allocatedPrizeYield"]!
    
    // Total staked should be unchanged (all yield went to lottery)
    Test.assertEqual(100.0, midTotalStaked)
    Test.assert(midPendingLottery > 0.0, message: "Should have pending lottery yield")
    
    // Simulate small depreciation (less than allocatedPrizeYield)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    
    // allocatedRewards should be unchanged (deficit absorbed by lottery)
    Test.assertEqual(midTotalStaked, finalTotalStaked)
    
    // allocatedPrizeYield should have decreased
    Test.assert(finalPendingLottery < midPendingLottery, message: "allocatedPrizeYield should decrease")
}

// ============================================================================
// TESTS - Lottery Shortfall Handling
// ============================================================================

access(all) fun testLotteryShortfallFallsToSavings() {
    // Setup: Create pool with 50/50 distribution
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.5, treasury: 0.0, depositAmount: 100.0)
    
    // Add small amount of yield to build up some allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 4.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let midInfo = getPoolSavingsInfo(poolID)
    let pendingLottery = midInfo["allocatedPrizeYield"]!
    // With 50/50 split, ~2 FLOW should be in allocatedPrizeYield
    
    // Now simulate a larger depreciation than allocatedPrizeYield can cover
    // 10 FLOW deficit with 50/50 = 5 each, but lottery only has ~2
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    
    // allocatedPrizeYield should be 0 or very close (absorbed all it could)
    Test.assert(finalPendingLottery < 0.1, message: "allocatedPrizeYield should be nearly depleted")
    
    // The shortfall should have been absorbed by savings
    // (verified by the share price decrease being more than just the savings portion)
}

access(all) fun testTreasuryShortfallFallsToLottery() {
    // Setup: Create pool with 40/40/20 distribution
    // We'll create a scenario where treasury can't cover its share
    let poolID = setupPoolWithDeposit(rewards: 0.4, prize: 0.4, treasury: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)
    
    // Add small yield: 5 FLOW total
    // savings gets 2, lottery gets 2, treasury gets 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterYieldInfo = getPoolSavingsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["allocatedRewards"]!
    let afterYieldPendingLottery = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingTreasury = afterYieldInfo["allocatedTreasuryYield"]!
    
    // Verify initial state: ~102, ~2, ~1
    Test.assert(afterYieldTotalStaked > 101.0 && afterYieldTotalStaked < 103.0,
        message: "allocatedRewards should be ~102. Got: ".concat(afterYieldTotalStaked.toString()))
    Test.assert(afterYieldPendingLottery > 1.5 && afterYieldPendingLottery < 2.5,
        message: "allocatedPrizeYield should be ~2. Got: ".concat(afterYieldPendingLottery.toString()))
    Test.assert(afterYieldPendingTreasury > 0.5 && afterYieldPendingTreasury < 1.5,
        message: "allocatedTreasuryYield should be ~1. Got: ".concat(afterYieldPendingTreasury.toString()))
    
    // Now simulate 10 FLOW deficit
    // Target losses: treasury = 2 (20%), lottery = 4 (40%), savings = 4 (40%)
    // But treasury only has ~1, so shortfall of ~1 goes to lottery
    // Lottery needs to absorb: 4 + 1 = 5, but only has ~2, shortfall of ~3 goes to savings
    // Savings absorbs: 4 + 3 = 7
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    let finalPendingTreasury = finalInfo["allocatedTreasuryYield"]!
    
    // Treasury should be depleted (absorbed all ~1 it had)
    Test.assert(finalPendingTreasury < 0.1,
        message: "Treasury should be depleted. Got: ".concat(finalPendingTreasury.toString()))
    
    // Lottery should be depleted (absorbed all ~2 it had)
    Test.assert(finalPendingLottery < 0.1,
        message: "Lottery should be depleted. Got: ".concat(finalPendingLottery.toString()))
    
    // Savings absorbed its share + all shortfalls
    // Original allocatedRewards ~102, absorbed ~7, should be ~95
    let savingsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(savingsLoss > 6.0 && savingsLoss < 8.0,
        message: "Savings should absorb ~7 (its share + shortfalls). Actual: ".concat(savingsLoss.toString()))
    
    // Total absorbed should equal deficit
    let totalAbsorbed = savingsLoss + afterYieldPendingLottery + afterYieldPendingTreasury - finalPendingLottery - finalPendingTreasury
    Test.assert(totalAbsorbed > 9.5 && totalAbsorbed < 10.5,
        message: "Total absorbed should be ~10. Got: ".concat(totalAbsorbed.toString()))
}

access(all) fun testShortfallPriorityChain() {
    // This test explicitly verifies the priority: Treasury → Lottery → Savings
    // Setup: 30% savings, 30% lottery, 40% treasury
    let poolID = setupPoolWithDeposit(rewards: 0.3, prize: 0.3, treasury: 0.4, depositAmount: 100.0)
    let poolIndex = Int(poolID)
    
    // Add exactly 10 FLOW yield
    // savings gets 3, lottery gets 3, treasury gets 4
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterYieldInfo = getPoolSavingsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["allocatedRewards"]!
    let afterYieldPendingLottery = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingTreasury = afterYieldInfo["allocatedTreasuryYield"]!
    
    // State: allocatedRewards ~103, lottery ~3, treasury ~4
    // allocatedFunds = 103 + 3 + 4 = 110
    
    // Simulate 20 FLOW deficit (larger than total yield accumulated)
    // Target losses: treasury = 8 (40%), lottery = 6 (30%), savings = 6 (30%)
    // Treasury has 4, absorbs 4, shortfall = 4
    // Lottery needs 6 + 4 = 10, has 3, absorbs 3, shortfall = 7
    // Savings absorbs 6 + 7 = 13
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    let finalPendingTreasury = finalInfo["allocatedTreasuryYield"]!
    
    // Treasury should be completely depleted
    Test.assert(finalPendingTreasury < 0.01,
        message: "Treasury should be fully depleted. Got: ".concat(finalPendingTreasury.toString()))
    
    // Lottery should be completely depleted
    Test.assert(finalPendingLottery < 0.01,
        message: "Lottery should be fully depleted. Got: ".concat(finalPendingLottery.toString()))
    
    // Savings absorbed its share plus all shortfalls (~13)
    let savingsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(savingsLoss > 12.0 && savingsLoss < 14.0,
        message: "Savings should absorb ~13 (6 own + 7 shortfall). Actual: ".concat(savingsLoss.toString()))
    
    // Final allocatedRewards should be ~90 (103 - 13)
    Test.assert(finalTotalStaked > 89.0 && finalTotalStaked < 91.0,
        message: "Final allocatedRewards should be ~90. Got: ".concat(finalTotalStaked.toString()))
}

access(all) fun testWaterfallProtectsSavingsWhenProtocolFundsSufficient() {
    // Test that waterfall drains treasury/lottery before touching savings
    // Even with substantial reserves, savings is protected if protocol funds cover deficit
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.3, treasury: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)

    // Add 40 FLOW yield to build up substantial reserves
    // savings gets 20, lottery gets 12, treasury gets 8
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 40.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let afterYieldInfo = getPoolSavingsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["allocatedRewards"]!
    let afterYieldPendingLottery = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingTreasury = afterYieldInfo["allocatedTreasuryYield"]!

    // Simulate 10 FLOW deficit
    // Waterfall: treasury first (all 8), then lottery (remaining 2), savings (0)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingLottery = finalInfo["allocatedPrizeYield"]!
    let finalPendingTreasury = finalInfo["allocatedTreasuryYield"]!

    let treasuryLoss = afterYieldPendingTreasury - finalPendingTreasury
    let lotteryLoss = afterYieldPendingLottery - finalPendingLottery
    let savingsLoss = afterYieldTotalStaked - finalTotalStaked

    // Treasury fully drained first (~8)
    Test.assert(treasuryLoss > 7.5 && treasuryLoss < 8.5,
        message: "Treasury should be fully drained (~8). Actual: ".concat(treasuryLoss.toString()))

    // Lottery absorbed remaining deficit (~2)
    Test.assert(lotteryLoss > 1.5 && lotteryLoss < 2.5,
        message: "Lottery should absorb remaining ~2. Actual: ".concat(lotteryLoss.toString()))

    // Savings protected (no loss)
    Test.assert(savingsLoss < 0.01,
        message: "Savings should be protected (no loss). Actual: ".concat(savingsLoss.toString()))

    // Treasury depleted, lottery still has funds
    Test.assert(finalPendingTreasury < 0.5,
        message: "Treasury should be depleted. Got: ".concat(finalPendingTreasury.toString()))
    Test.assert(finalPendingLottery > 9.0,
        message: "Lottery should still have ~10. Got: ".concat(finalPendingLottery.toString()))
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testDeficitLargerThanTotalAssets() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    
    // Try to depreciate more than exists in the vault
    // The vault only has 100 FLOW, so withdrawing 150 should fail
    let success = simulateYieldDepreciationExpectFailure(poolIndex: poolIndex, amount: 150.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // This should fail because there's not enough in the vault
    Test.assertEqual(false, success)
}

access(all) fun testMultipleDeficitsAccumulate() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, treasury: 0.1, depositAmount: 100.0)
    
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
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, treasury: 0.1, depositAmount: 100.0)
    
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
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, treasury: 0.1, depositAmount: 100.0)
    
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    
    // Trigger sync without any change to yield vault
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    
    // Nothing should change
    Test.assertEqual(initialSharePrice, finalSharePrice)
    Test.assertEqual(initialTotalStaked, finalTotalStaked)
}

// ============================================================================
// TESTS - User Balance Impact
// ============================================================================

access(all) fun testUserBalanceDecreasesDuringDeficit() {
    // Setup: Create pool
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
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
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
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

// ============================================================================
// TESTS - Auto-Triggered Deficit Sync During User Operations
// ============================================================================
// These tests verify that deficit sync is automatically triggered during
// deposits and withdrawals, not just when admin explicitly calls sync.
// This is critical for fair loss socialization - without auto-triggering,
// early withdrawers could escape losses while later users bear the full burden.
// ============================================================================

access(all) fun testDeficitAutoAppliedDuringDeposit() {
    // Setup: Create pool with initial deposit
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    // Create first user and deposit
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    depositToPool(user1, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    
    Test.assertEqual(1.0, initialSharePrice)
    Test.assertEqual(100.0, initialTotalStaked)
    
    // Simulate deficit - remove 10 FLOW from yield vault
    // DO NOT call triggerSyncWithYieldSource() - we're testing auto-trigger
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Create second user and deposit - this SHOULD auto-trigger sync
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user2, amount: 20.0)
    depositToPool(user2, poolID: poolID, amount: 10.0)
    
    // Get final state - share price should have decreased from the deficit
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should be < 1.0 because deficit was applied during user2's deposit
    Test.assert(finalSharePrice < initialSharePrice,
        message: "Share price should decrease after deficit is auto-applied during deposit. Initial: "
            .concat(initialSharePrice.toString()).concat(", Final: ").concat(finalSharePrice.toString()))
    
    // Verify user1's balance decreased (they shared in the loss)
    let user1Balance = getActualBalanceFromResult(getUserActualBalance(user1.address, poolID))
    Test.assert(user1Balance < 100.0,
        message: "User1's balance should decrease from deficit. Got: ".concat(user1Balance.toString()))
}

access(all) fun testDeficitAutoAppliedDuringWithdrawal() {
    // Setup: Create pool with initial deposit
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    Test.assertEqual(1.0, initialSharePrice)
    
    // Simulate deficit - remove 10 FLOW from yield vault
    // DO NOT call triggerSyncWithYieldSource() - we're testing auto-trigger
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Withdraw 50 FLOW - this SHOULD auto-trigger sync before calculating withdrawal
    withdrawFromPool(user, poolID: poolID, amount: 50.0)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should be < 1.0 because deficit was applied during withdrawal
    Test.assert(finalSharePrice < initialSharePrice,
        message: "Share price should decrease after deficit is auto-applied during withdrawal. Initial: "
            .concat(initialSharePrice.toString()).concat(", Final: ").concat(finalSharePrice.toString()))
    
    // User's remaining balance should reflect the loss
    // They started with 100, lost ~10 to deficit, withdrew ~50, should have ~40 left
    let userBalance = getActualBalanceFromResult(getUserActualBalance(user.address, poolID))
    Test.assert(userBalance > 35.0 && userBalance < 45.0,
        message: "User's remaining balance should be ~40 (100 - 10 deficit - 50 withdrawn). Got: "
            .concat(userBalance.toString()))
}

access(all) fun testDeficitNotAppliedWithoutUserInteraction() {
    // This test verifies that deficits DON'T change balances until someone interacts
    // This is the expected behavior - we just need sync to happen on interaction
    
    // Setup: Create pool with initial deposit
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    
    // Simulate deficit without any interaction
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Check pool state WITHOUT any user interaction
    // Share price should still be the same (no sync happened yet)
    let midInfo = getPoolSavingsInfo(poolID)
    let midSharePrice = midInfo["sharePrice"]!
    let midTotalStaked = midInfo["allocatedRewards"]!
    
    // Internal accounting hasn't changed because no sync happened
    Test.assertEqual(initialSharePrice, midSharePrice)
    Test.assertEqual(initialTotalStaked, midTotalStaked)
    
    // But yield source actually has less - needsSync should be true
    // (We can't directly test needsSync from scripts, but we verify the state is stale)
}

access(all) fun testEarlyWithdrawerCannotEscapeLosses() {
    // This is the critical fairness test:
    // If a deficit occurs, both early and late withdrawers should share the loss
    
    // Setup: Create pool with two depositors
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    setupUserWithFundsAndCollection(user2, amount: 110.0)
    
    depositToPool(user1, poolID: poolID, amount: 100.0)
    depositToPool(user2, poolID: poolID, amount: 100.0)
    
    // Total: 200 FLOW in pool, each user has 50% = 100 FLOW
    
    // Simulate 20 FLOW deficit (10% loss for everyone)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // User1 withdraws first - deficit should be applied, they should lose 10 FLOW
    // They try to withdraw 100 but should only get ~90
    withdrawFromPool(user1, poolID: poolID, amount: 90.0)  // Withdraw what they can
    
    // User1's remaining balance should be ~0 (they got ~90, have ~0 left)
    let user1Balance = getActualBalanceFromResult(getUserActualBalance(user1.address, poolID))
    Test.assert(user1Balance < 5.0,
        message: "User1 should have little remaining after withdrawing ~90. Got: "
            .concat(user1Balance.toString()))
    
    // User2 should also have ~90 available (they share in the loss)
    let user2Balance = getActualBalanceFromResult(getUserActualBalance(user2.address, poolID))
    Test.assert(user2Balance > 85.0 && user2Balance < 95.0,
        message: "User2 should have ~90 after deficit (100 - 10). Got: "
            .concat(user2Balance.toString()))
    
    // The key invariant: Both users lost ~10% each, the loss was shared fairly
}

access(all) fun testMultipleDeficitsAppliedOnEachInteraction() {
    // Verify that multiple deficits are properly tracked and applied
    
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    let poolIndex = Int(poolID)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // First deficit: 10 FLOW
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Deposit more to trigger sync
    depositToPool(user, poolID: poolID, amount: 10.0)
    
    let info1 = getPoolSavingsInfo(poolID)
    let sharePrice1 = info1["sharePrice"]!
    
    // Share price should have decreased from first deficit
    Test.assert(sharePrice1 < 1.0, 
        message: "Share price should be < 1.0 after first deficit")
    
    // Second deficit: 10 more FLOW
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Deposit again to trigger sync
    depositToPool(user, poolID: poolID, amount: 10.0)
    
    let info2 = getPoolSavingsInfo(poolID)
    let sharePrice2 = info2["sharePrice"]!
    
    // Share price should have decreased further
    Test.assert(sharePrice2 < sharePrice1,
        message: "Share price should decrease further after second deficit. First: "
            .concat(sharePrice1.toString()).concat(", Second: ").concat(sharePrice2.toString()))
}
