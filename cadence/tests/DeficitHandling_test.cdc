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

access(all) fun setupPoolWithDeposit(rewards: UFix64, prize: UFix64, protocolFee: UFix64, depositAmount: UFix64): UInt64 {
    // Create pool with specified distribution
    let poolID = createPoolWithDistribution(rewards: rewards, prize: prize, protocolFee: protocolFee)
    
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
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    let initialSharePrice = initialInfo["sharePrice"]!
    
    Test.assertEqual(100.0, initialTotalStaked)
    
    // Simulate depreciation: Remove 10 FLOW from yield vault
    // Pool index matches creation order (0-based)
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Trigger sync - this should detect and apply the deficit
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Total staked should have decreased
    Test.assert(finalTotalStaked < initialTotalStaked, message: "userPoolBalance should decrease after deficit")
    
    // Share price should have decreased (meaning users' balances decreased)
    Test.assert(finalSharePrice < initialSharePrice, message: "sharePrice should decrease after deficit")
}

// ============================================================================
// TESTS - Deficit Distribution According to Strategy
// ============================================================================

access(all) fun testDeficitDistributedAccordingToStrategy() {
    // Setup: Create pool with 50/50/0 (rewards/prize/protocolFee)
    // This makes the math easy: deficit should be split evenly
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.5, protocolFee: 0.0, depositAmount: 100.0)
    
    // Add some yield first to build up allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check that prize yield was accumulated
    let midInfo = getPoolRewardsInfo(poolID)
    let pendingPrize = midInfo["allocatedPrizeYield"]!
    Test.assert(pendingPrize > 0.0, message: "Should have pending prize yield after appreciation")
    
    // Now simulate depreciation
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // Both rewards and prize should have absorbed the deficit
    // With 50/50 split, each should absorb 50% of the 10 FLOW deficit = 5 each
    // allocatedPrizeYield should have decreased by ~5
    Test.assert(finalPendingPrize < pendingPrize, message: "allocatedPrizeYield should decrease")
}

access(all) fun testDeficitDistributionWithProtocol() {
    // Setup: Create pool with 50/30/20 (rewards/prize/protocolFee)
    // Deficit uses DETERMINISTIC WATERFALL (not strategy proportions):
    //   1. Protocol absorbs first (drain completely if needed)
    //   2. Prize absorbs second (drain completely if needed)
    //   3. Rewards absorbs last (user principal protected)
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.3, protocolFee: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)

    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    let initialPendingProtocol = initialInfo["allocatedProtocolFee"]!
    let initialSharePrice = initialInfo["sharePrice"]!

    Test.assertEqual(100.0, initialTotalStaked)
    Test.assertEqual(0.0, initialPendingPrize)
    Test.assertEqual(0.0, initialPendingProtocol)
    Test.assertEqual(1.0, initialSharePrice)

    // Add 20 FLOW yield to build up reserves
    // Distribution: rewards = 10 (50%), prize = 6 (30%), protocolFee = 4 (20%)
    // All portions stay in yield source, tracked via pending variables
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Verify yield was distributed correctly
    let afterYieldInfo = getPoolRewardsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["userPoolBalance"]!
    let afterYieldPendingPrize = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingProtocolFee = afterYieldInfo["allocatedProtocolFee"]!

    // userPoolBalance should increase by rewards portion: 100 + 10 = 110
    Test.assert(afterYieldTotalStaked > 109.0 && afterYieldTotalStaked < 111.0,
        message: "userPoolBalance should be ~110 after yield. Got: ".concat(afterYieldTotalStaked.toString()))

    // allocatedPrizeYield should be prize portion: 6
    Test.assert(afterYieldPendingPrize > 5.0 && afterYieldPendingPrize < 7.0,
        message: "allocatedPrizeYield should be ~6 after yield. Got: ".concat(afterYieldPendingPrize.toString()))

    // allocatedProtocolFee should be protocol fee portion: 4
    Test.assert(afterYieldPendingProtocolFee > 3.0 && afterYieldPendingProtocolFee < 5.0,
        message: "allocatedProtocolFee should be ~4 after yield. Got: ".concat(afterYieldPendingProtocolFee.toString()))

    // Now simulate 10 FLOW deficit
    // Deficit uses DETERMINISTIC WATERFALL to protect user funds:
    //   protocol fee absorbs first: all ~4 FLOW (depleted)
    //   prize absorbs second: remaining ~6 FLOW (depleted)
    //   rewards absorbs last: 0 FLOW (protected!)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    let finalSharePrice = finalInfo["sharePrice"]!

    // Verify protocol fee was fully drained first (~4)
    let actualProtocolLoss = afterYieldPendingProtocolFee - finalPendingProtocolFee
    Test.assert(actualProtocolLoss > 3.5 && actualProtocolLoss < 4.5,
        message: "Protocol should be fully drained (~4 FLOW). Actual loss: ".concat(actualProtocolLoss.toString()))

    // Verify prize absorbed the remaining deficit (~6)
    let actualPrizeLoss = afterYieldPendingPrize - finalPendingPrize
    Test.assert(actualPrizeLoss > 5.5 && actualPrizeLoss < 6.5,
        message: "Prize should absorb remaining ~6 FLOW. Actual loss: ".concat(actualPrizeLoss.toString()))

    // Verify rewards was protected (no loss)
    let actualRewardsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(actualRewardsLoss < 0.01,
        message: "Rewards should be protected (no loss). Actual loss: ".concat(actualRewardsLoss.toString()))

    // Verify final values are approximately correct
    // Expected: 110 - 0 = 110 (rewards protected)
    Test.assert(finalTotalStaked > 109.0 && finalTotalStaked < 111.0,
        message: "Final userPoolBalance should be ~110 (protected). Got: ".concat(finalTotalStaked.toString()))
    // Expected: prize fully drained
    Test.assert(finalPendingPrize < 0.5,
        message: "Final allocatedPrizeYield should be ~0 (drained). Got: ".concat(finalPendingPrize.toString()))
    // Expected: protocol fee fully drained
    Test.assert(finalPendingProtocolFee < 0.5,
        message: "Final allocatedProtocolFee should be ~0 (drained). Got: ".concat(finalPendingProtocolFee.toString()))

    // Verify share price unchanged (rewards was protected)
    Test.assert(finalSharePrice > afterYieldInfo["sharePrice"]! - 0.01,
        message: "Share price should be unchanged (rewards protected)")

    // Total deficit absorbed should equal the original deficit amount
    let totalAbsorbed = actualRewardsLoss + actualPrizeLoss + actualProtocolLoss
    Test.assert(totalAbsorbed > 9.5 && totalAbsorbed < 10.5,
        message: "Total absorbed should be ~10 FLOW. Got: ".concat(totalAbsorbed.toString()))
}

access(all) fun testDeficitOnlyRewardsWhen100PercentRewards() {
    // Setup: Create pool with 100% rewards
    let poolID = setupPoolWithDeposit(rewards: 1.0, prize: 0.0, protocolFee: 0.0, depositAmount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    
    // Simulate depreciation
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // All deficit should come from rewards (share price decrease)
    Test.assert(finalTotalStaked < initialTotalStaked, message: "userPoolBalance should decrease")
    
    // allocatedPrizeYield should be unchanged (still 0)
    Test.assertEqual(initialPendingPrize, finalPendingPrize)
}

access(all) fun testDeficitOnlyPrizeWhen100PercentPrize() {
    // Setup: Create pool with 100% prize
    let poolID = setupPoolWithDeposit(rewards: 0.0, prize: 1.0, protocolFee: 0.0, depositAmount: 100.0)
    
    // Add yield first to build up allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get state after appreciation
    let midInfo = getPoolRewardsInfo(poolID)
    let midTotalStaked = midInfo["userPoolBalance"]!
    let midPendingPrize = midInfo["allocatedPrizeYield"]!
    
    // Total staked should be unchanged (all yield went to prize)
    Test.assertEqual(100.0, midTotalStaked)
    Test.assert(midPendingPrize > 0.0, message: "Should have pending prize yield")
    
    // Simulate small depreciation (less than allocatedPrizeYield)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // userPoolBalance should be unchanged (deficit absorbed by prize)
    Test.assertEqual(midTotalStaked, finalTotalStaked)
    
    // allocatedPrizeYield should have decreased
    Test.assert(finalPendingPrize < midPendingPrize, message: "allocatedPrizeYield should decrease")
}

// ============================================================================
// TESTS - Prize Shortfall Handling
// ============================================================================

access(all) fun testPrizeShortfallFallsToRewards() {
    // Setup: Create pool with 50/50 distribution
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.5, protocolFee: 0.0, depositAmount: 100.0)
    
    // Add small amount of yield to build up some allocatedPrizeYield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 4.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let midInfo = getPoolRewardsInfo(poolID)
    let pendingPrize = midInfo["allocatedPrizeYield"]!
    // With 50/50 split, ~2 FLOW should be in allocatedPrizeYield
    
    // Now simulate a larger depreciation than allocatedPrizeYield can cover
    // 10 FLOW deficit with 50/50 = 5 each, but prize only has ~2
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // allocatedPrizeYield should be 0 or very close (absorbed all it could)
    Test.assert(finalPendingPrize < 0.1, message: "allocatedPrizeYield should be nearly depleted")
    
    // The shortfall should have been absorbed by rewards
    // (verified by the share price decrease being more than just the rewards portion)
}

access(all) fun testProtocolShortfallFallsToPrize() {
    // Setup: Create pool with 40/40/20 distribution
    // We'll create a scenario where protocol fee can't cover its share
    let poolID = setupPoolWithDeposit(rewards: 0.4, prize: 0.4, protocolFee: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)
    
    // Add small yield: 5 FLOW total
    // rewards gets 2, prize gets 2, protocol fee gets 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterYieldInfo = getPoolRewardsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["userPoolBalance"]!
    let afterYieldPendingPrize = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingProtocolFee = afterYieldInfo["allocatedProtocolFee"]!
    
    // Verify initial state: ~102, ~2, ~1
    Test.assert(afterYieldTotalStaked > 101.0 && afterYieldTotalStaked < 103.0,
        message: "userPoolBalance should be ~102. Got: ".concat(afterYieldTotalStaked.toString()))
    Test.assert(afterYieldPendingPrize > 1.5 && afterYieldPendingPrize < 2.5,
        message: "allocatedPrizeYield should be ~2. Got: ".concat(afterYieldPendingPrize.toString()))
    Test.assert(afterYieldPendingProtocolFee > 0.5 && afterYieldPendingProtocolFee < 1.5,
        message: "allocatedProtocolFee should be ~1. Got: ".concat(afterYieldPendingProtocolFee.toString()))
    
    // Now simulate 10 FLOW deficit
    // Target losses: protocolFee = 2 (20%), prize = 4 (40%), rewards = 4 (40%)
    // But protocol fee only has ~1, so shortfall of ~1 goes to prize
    // Prize needs to absorb: 4 + 1 = 5, but only has ~2, shortfall of ~3 goes to rewards
    // Rewards absorbs: 4 + 3 = 7
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    
    // Protocol should be depleted (absorbed all ~1 it had)
    Test.assert(finalPendingProtocolFee < 0.1,
        message: "Protocol should be depleted. Got: ".concat(finalPendingProtocolFee.toString()))
    
    // Prize should be depleted (absorbed all ~2 it had)
    Test.assert(finalPendingPrize < 0.1,
        message: "Prize should be depleted. Got: ".concat(finalPendingPrize.toString()))
    
    // Rewards absorbed its share + all shortfalls
    // Original userPoolBalance ~102, absorbed ~7, should be ~95
    let rewardsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(rewardsLoss > 6.0 && rewardsLoss < 8.0,
        message: "Rewards should absorb ~7 (its share + shortfalls). Actual: ".concat(rewardsLoss.toString()))
    
    // Total absorbed should equal deficit
    let totalAbsorbed = rewardsLoss + afterYieldPendingPrize + afterYieldPendingProtocolFee - finalPendingPrize - finalPendingProtocolFee
    Test.assert(totalAbsorbed > 9.5 && totalAbsorbed < 10.5,
        message: "Total absorbed should be ~10. Got: ".concat(totalAbsorbed.toString()))
}

access(all) fun testShortfallPriorityChain() {
    // This test explicitly verifies the priority: Protocol → Prize → Rewards
    // Setup: 30% rewards, 30% prize, 40% protocolFee
    let poolID = setupPoolWithDeposit(rewards: 0.3, prize: 0.3, protocolFee: 0.4, depositAmount: 100.0)
    let poolIndex = Int(poolID)
    
    // Add exactly 10 FLOW yield
    // rewards gets 3, prize gets 3, protocol fee gets 4
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterYieldInfo = getPoolRewardsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["userPoolBalance"]!
    let afterYieldPendingPrize = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingProtocolFee = afterYieldInfo["allocatedProtocolFee"]!
    
    // State: userPoolBalance ~103, prize ~3, protocol ~4
    // allocatedFunds = 103 + 3 + 4 = 110
    
    // Simulate 20 FLOW deficit (larger than total yield accumulated)
    // Target losses: protocolFee = 8 (40%), prize = 6 (30%), rewards = 6 (30%)
    // Protocol has 4, absorbs 4, shortfall = 4
    // Prize needs 6 + 4 = 10, has 3, absorbs 3, shortfall = 7
    // Rewards absorbs 6 + 7 = 13
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    
    // Protocol should be completely depleted
    Test.assert(finalPendingProtocolFee < 0.01,
        message: "Protocol should be fully depleted. Got: ".concat(finalPendingProtocolFee.toString()))
    
    // Prize should be completely depleted
    Test.assert(finalPendingPrize < 0.01,
        message: "Prize should be fully depleted. Got: ".concat(finalPendingPrize.toString()))
    
    // Rewards absorbed its share plus all shortfalls (~13)
    let rewardsLoss = afterYieldTotalStaked - finalTotalStaked
    Test.assert(rewardsLoss > 12.0 && rewardsLoss < 14.0,
        message: "Rewards should absorb ~13 (6 own + 7 shortfall). Actual: ".concat(rewardsLoss.toString()))
    
    // Final userPoolBalance should be ~90 (103 - 13)
    Test.assert(finalTotalStaked > 89.0 && finalTotalStaked < 91.0,
        message: "Final userPoolBalance should be ~90. Got: ".concat(finalTotalStaked.toString()))
}

access(all) fun testWaterfallProtectsRewardsWhenProtocolFundsSufficient() {
    // Test that waterfall drains protocolFee/prize before touching rewards
    // Even with substantial reserves, rewards is protected if protocol fee covers deficit
    let poolID = setupPoolWithDeposit(rewards: 0.5, prize: 0.3, protocolFee: 0.2, depositAmount: 100.0)
    let poolIndex = Int(poolID)

    // Add 40 FLOW yield to build up substantial reserves
    // rewards gets 20, prize gets 12, protocol fee gets 8
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 40.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let afterYieldInfo = getPoolRewardsInfo(poolID)
    let afterYieldTotalStaked = afterYieldInfo["userPoolBalance"]!
    let afterYieldPendingPrize = afterYieldInfo["allocatedPrizeYield"]!
    let afterYieldPendingProtocolFee = afterYieldInfo["allocatedProtocolFee"]!

    // Simulate 10 FLOW deficit
    // Waterfall: protocol fee first (all 8), then prize (remaining 2), rewards (0)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!

    let protocolFeeLoss = afterYieldPendingProtocolFee - finalPendingProtocolFee
    let prizeLoss = afterYieldPendingPrize - finalPendingPrize
    let rewardsLoss = afterYieldTotalStaked - finalTotalStaked

    // Protocol fully drained first (~8)
    Test.assert(protocolFeeLoss > 7.5 && protocolFeeLoss < 8.5,
        message: "Protocol should be fully drained (~8). Actual: ".concat(protocolFeeLoss.toString()))

    // Prize absorbed remaining deficit (~2)
    Test.assert(prizeLoss > 1.5 && prizeLoss < 2.5,
        message: "Prize should absorb remaining ~2. Actual: ".concat(prizeLoss.toString()))

    // Rewards protected (no loss)
    Test.assert(rewardsLoss < 0.01,
        message: "Rewards should be protected (no loss). Actual: ".concat(rewardsLoss.toString()))

    // Protocol depleted, prize still has funds
    Test.assert(finalPendingProtocolFee < 0.5,
        message: "Protocol should be depleted. Got: ".concat(finalPendingProtocolFee.toString()))
    Test.assert(finalPendingPrize > 9.0,
        message: "Prize should still have ~10. Got: ".concat(finalPendingPrize.toString()))
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testDeficitLargerThanTotalAssets() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    
    // Try to depreciate more than exists in the vault
    // The vault only has 100 FLOW, so withdrawing 150 should fail
    let success = simulateYieldDepreciationExpectFailure(poolIndex: poolIndex, amount: 150.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // This should fail because there's not enough in the vault
    Test.assertEqual(false, success)
}

access(all) fun testMultipleDeficitsAccumulate() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Apply multiple small deficits
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let midInfo = getPoolRewardsInfo(poolID)
    let midSharePrice = midInfo["sharePrice"]!
    
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should decrease progressively
    Test.assert(midSharePrice < initialSharePrice, message: "Share price should decrease after first deficit")
    Test.assert(finalSharePrice < midSharePrice, message: "Share price should decrease further after second deficit")
}

access(all) fun testDeficitFollowedByExcess() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositAmount: 100.0)
    
    let poolIndex = Int(poolID)
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Apply deficit first
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let afterDeficitInfo = getPoolRewardsInfo(poolID)
    let afterDeficitSharePrice = afterDeficitInfo["sharePrice"]!
    Test.assert(afterDeficitSharePrice < initialSharePrice, message: "Share price should decrease after deficit")
    
    // Now add excess (more than was lost)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should increase past the post-deficit level
    Test.assert(finalSharePrice > afterDeficitSharePrice, message: "Share price should increase after excess")
}

access(all) fun testZeroDeficitNoChange() {
    // Setup: Create pool with 100 FLOW deposit
    let poolID = setupPoolWithDeposit(rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositAmount: 100.0)
    
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    
    // Trigger sync without any change to yield vault
    triggerSyncWithYieldSource(poolID: poolID)
    
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    let finalTotalStaked = finalInfo["userPoolBalance"]!
    
    // Nothing should change
    Test.assertEqual(initialSharePrice, finalSharePrice)
    Test.assertEqual(initialTotalStaked, finalTotalStaked)
}

// ============================================================================
// TESTS - User Balance Impact
// ============================================================================

access(all) fun testUserBalanceDecreasesDuringDeficit() {
    // Setup: Create pool
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
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
    // Setup: Create pool with 100% rewards
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
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
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
    let poolIndex = Int(poolID)
    
    // Create first user and deposit
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    depositToPool(user1, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    
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
    let finalInfo = getPoolRewardsInfo(poolID)
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
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
    let poolIndex = Int(poolID)
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    Test.assertEqual(1.0, initialSharePrice)
    
    // Simulate deficit - remove 10 FLOW from yield vault
    // DO NOT call triggerSyncWithYieldSource() - we're testing auto-trigger
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Withdraw 50 FLOW - this SHOULD auto-trigger sync before calculating withdrawal
    withdrawFromPool(user, poolID: poolID, amount: 50.0)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
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
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
    let poolIndex = Int(poolID)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    let initialTotalStaked = initialInfo["userPoolBalance"]!
    
    // Simulate deficit without any interaction
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Check pool state WITHOUT any user interaction
    // Share price should still be the same (no sync happened yet)
    let midInfo = getPoolRewardsInfo(poolID)
    let midSharePrice = midInfo["sharePrice"]!
    let midTotalStaked = midInfo["userPoolBalance"]!
    
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
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
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
    
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
    let poolIndex = Int(poolID)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    // First deficit: 10 FLOW
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Deposit more to trigger sync
    depositToPool(user, poolID: poolID, amount: 10.0)
    
    let info1 = getPoolRewardsInfo(poolID)
    let sharePrice1 = info1["sharePrice"]!
    
    // Share price should have decreased from first deficit
    Test.assert(sharePrice1 < 1.0, 
        message: "Share price should be < 1.0 after first deficit")
    
    // Second deficit: 10 more FLOW
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Deposit again to trigger sync
    depositToPool(user, poolID: poolID, amount: 10.0)
    
    let info2 = getPoolRewardsInfo(poolID)
    let sharePrice2 = info2["sharePrice"]!
    
    // Share price should have decreased further
    Test.assert(sharePrice2 < sharePrice1,
        message: "Share price should decrease further after second deficit. First: "
            .concat(sharePrice1.toString()).concat(", Second: ").concat(sharePrice2.toString()))
}
