import Test
import "test_helpers.cdc"

// ============================================================================
// PROJECTED PRIZE POOL & SHARE PRICE TEST SUITE
// ============================================================================
//
// Tests for the projected prize pool balance and projected share price features:
// view-only preview functions that calculate what these values would be if
// syncWithYieldSource() were called right now. This enables real-time display
// without mutating contract state.
//
// Functions under test:
// - Pool.getProjectedPrizePoolBalance()
// - Pool.getProjectedSharePrice()
// - PrizeLinkedAccounts.getProjectedPrizePoolBalance() (contract-level)
// - PrizeLinkedAccounts.getProjectedSharePrice() (contract-level)
//
// The projected share price is also used internally by getProjectedUserBalance(),
// so these tests transitively validate that refactoring as well.
// ============================================================================

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Projected Prize Pool Equals Synced When No Unsync'd Yield
// ============================================================================

access(all) fun testProjectedPrizePoolEqualsSyncedWhenNoYield() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // No unsync'd yield — projected should equal synced
    let result = getProjectedPrizePoolBalance(poolID)
    let projected = result["projectedPrizePoolBalance"]!
    let synced = result["syncedPrizePoolBalance"]!

    Test.assertEqual(projected, synced)
}

// ============================================================================
// TEST: Projected Prize Pool Reflects Unsync'd Yield
// ============================================================================

access(all) fun testProjectedPrizePoolReflectsUnsyncdYield() {
    // 70% rewards, 20% prize, 10% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate yield appreciation WITHOUT syncing
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected should be higher than synced (unsync'd yield)
    let beforeSync = getProjectedPrizePoolBalance(poolID)
    let projectedBefore = beforeSync["projectedPrizePoolBalance"]!
    let syncedBefore = beforeSync["syncedPrizePoolBalance"]!

    Test.assert(
        projectedBefore > syncedBefore,
        message: "Projected prize pool should be > synced with unsync'd yield. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Synced: ").concat(syncedBefore.toString())
    )

    // Now sync and verify they converge
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedPrizePoolBalance(poolID)
    let projectedAfter = afterSync["projectedPrizePoolBalance"]!
    let syncedAfter = afterSync["syncedPrizePoolBalance"]!

    Test.assertEqual(projectedAfter, syncedAfter)

    // Synced after sync should match projected before sync
    Test.assert(
        isWithinTolerance(syncedAfter, projectedBefore, 0.00000002),
        message: "Synced after sync should match projected before sync. Synced: "
            .concat(syncedAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Projected Prize Pool Reflects Deficit
// ============================================================================

access(all) fun testProjectedPrizePoolReflectsDeficit() {
    // 50% rewards, 20% prize, 30% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.2, protocolFee: 0.3)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // First, add yield and sync to build up prize and protocol allocations
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Verify we have prize yield allocated
    let rewardsInfo = getPoolRewardsInfo(poolID)
    let allocatedPrizeYield = rewardsInfo["allocatedPrizeYield"]!
    Test.assert(allocatedPrizeYield > 0.0, message: "Should have prize yield allocation after sync")

    // Now simulate a deficit that fits within the prize allocation
    // Prize has 20% of 20 = 4.0, protocol has 30% of 20 = 6.0
    // A deficit of 5.0 would drain protocol (6.0) first, leaving prize untouched
    // A deficit of 8.0 would drain protocol (6.0) then prize (2.0 of 4.0)
    let deficitAmount = 8.0
    simulateYieldDepreciation(poolIndex: poolIndex, amount: deficitAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected should be lower than synced (unsync'd deficit hits prize)
    let beforeSync = getProjectedPrizePoolBalance(poolID)
    let projectedBefore = beforeSync["projectedPrizePoolBalance"]!
    let syncedBefore = beforeSync["syncedPrizePoolBalance"]!

    Test.assert(
        projectedBefore < syncedBefore,
        message: "Projected prize pool should be < synced with deficit hitting prize. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Synced: ").concat(syncedBefore.toString())
    )

    // Sync and verify convergence
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedPrizePoolBalance(poolID)
    let syncedAfter = afterSync["syncedPrizePoolBalance"]!

    Test.assert(
        isWithinTolerance(syncedAfter, projectedBefore, 0.00000002),
        message: "Synced after sync should match projected before sync. Synced: "
            .concat(syncedAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Projected Prize Pool Deficit Absorbed By Protocol Fee Only
// ============================================================================

access(all) fun testProjectedPrizePoolDeficitAbsorbedByProtocol() {
    // 50% rewards, 20% prize, 30% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.2, protocolFee: 0.3)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Build up allocations
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let rewardsInfo = getPoolRewardsInfo(poolID)
    let allocatedPrizeYield = rewardsInfo["allocatedPrizeYield"]!
    let allocatedProtocolFee = rewardsInfo["allocatedProtocolFee"]!

    // Deficit small enough to be fully absorbed by protocol fee
    let smallDeficit = allocatedProtocolFee * 0.5
    simulateYieldDepreciation(poolIndex: poolIndex, amount: smallDeficit, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected prize pool should equal synced — deficit absorbed by protocol, not prize
    let result = getProjectedPrizePoolBalance(poolID)
    let projected = result["projectedPrizePoolBalance"]!
    let synced = result["syncedPrizePoolBalance"]!

    Test.assert(
        isWithinTolerance(projected, synced, 0.00000002),
        message: "Small deficit absorbed by protocol fee should not affect prize pool. Projected: "
            .concat(projected.toString())
            .concat(", Synced: ").concat(synced.toString())
    )
}

// ============================================================================
// TEST: Projected Share Price Equals Synced When No Unsync'd Yield
// ============================================================================

access(all) fun testProjectedSharePriceEqualsSyncedWhenNoYield() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // No unsync'd yield — projected should equal synced
    let result = getProjectedSharePrice(poolID)
    let projected = result["projectedSharePrice"]!
    let synced = result["syncedSharePrice"]!

    Test.assertEqual(projected, synced)
}

// ============================================================================
// TEST: Projected Share Price Reflects Unsync'd Yield
// ============================================================================

access(all) fun testProjectedSharePriceReflectsUnsyncdYield() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate yield appreciation WITHOUT syncing
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: "testYieldVaultShort_")

    // Projected should be higher than synced (unsync'd yield increases share price)
    let beforeSync = getProjectedSharePrice(poolID)
    let projectedBefore = beforeSync["projectedSharePrice"]!
    let syncedBefore = beforeSync["syncedSharePrice"]!

    Test.assert(
        projectedBefore > syncedBefore,
        message: "Projected share price should be > synced with unsync'd yield. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Synced: ").concat(syncedBefore.toString())
    )

    // Now sync and verify they converge
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedSharePrice(poolID)
    let projectedAfter = afterSync["projectedSharePrice"]!
    let syncedAfter = afterSync["syncedSharePrice"]!

    Test.assertEqual(projectedAfter, syncedAfter)

    // Synced after sync should match projected before sync
    Test.assert(
        isWithinTolerance(syncedAfter, projectedBefore, 0.00000002),
        message: "Synced share price after sync should match projected before sync. Synced: "
            .concat(syncedAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Projected Share Price Reflects Deficit
// ============================================================================

access(all) fun testProjectedSharePriceReflectsDeficit() {
    // 70% rewards, 20% prize, 10% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate depreciation WITHOUT syncing
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected should be lower than synced (deficit reduces share price)
    let beforeSync = getProjectedSharePrice(poolID)
    let projectedBefore = beforeSync["projectedSharePrice"]!
    let syncedBefore = beforeSync["syncedSharePrice"]!

    Test.assert(
        projectedBefore < syncedBefore,
        message: "Projected share price should be < synced with deficit. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Synced: ").concat(syncedBefore.toString())
    )

    // Sync and verify convergence
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedSharePrice(poolID)
    let syncedAfter = afterSync["syncedSharePrice"]!

    Test.assert(
        isWithinTolerance(syncedAfter, projectedBefore, 0.00000002),
        message: "Synced share price after sync should match projected before sync. Synced: "
            .concat(syncedAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Projected Share Price Deficit Absorbed By Protocol Fee
// ============================================================================

access(all) fun testProjectedSharePriceDeficitAbsorbedByProtocol() {
    // 50% rewards, 20% prize, 30% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.2, protocolFee: 0.3)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Build up allocations
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    let rewardsInfo = getPoolRewardsInfo(poolID)
    let allocatedProtocolFee = rewardsInfo["allocatedProtocolFee"]!

    // Record synced share price after yield sync
    let syncedInfo = getProjectedSharePrice(poolID)
    let syncedSharePrice = syncedInfo["syncedSharePrice"]!

    // Deficit small enough to be fully absorbed by protocol fee
    let smallDeficit = allocatedProtocolFee * 0.5
    simulateYieldDepreciation(poolIndex: poolIndex, amount: smallDeficit, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected share price should equal synced — deficit absorbed by protocol, not rewards
    let result = getProjectedSharePrice(poolID)
    let projected = result["projectedSharePrice"]!

    Test.assert(
        isWithinTolerance(projected, syncedSharePrice, 0.00000002),
        message: "Small deficit absorbed by protocol fee should not affect share price. Projected: "
            .concat(projected.toString())
            .concat(", Synced: ").concat(syncedSharePrice.toString())
    )
}

// ============================================================================
// TEST: Below-Threshold Difference Returns Synced Values
// ============================================================================

access(all) fun testBelowThresholdReturnsSynced() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // No yield manipulation — difference is 0 (below threshold)
    // Both projected values should exactly equal synced values
    let prizeResult = getProjectedPrizePoolBalance(poolID)
    Test.assertEqual(
        prizeResult["projectedPrizePoolBalance"]!,
        prizeResult["syncedPrizePoolBalance"]!
    )

    let priceResult = getProjectedSharePrice(poolID)
    Test.assertEqual(
        priceResult["projectedSharePrice"]!,
        priceResult["syncedSharePrice"]!
    )
}

// ============================================================================
// TEST: Projected User Balance Still Works After Refactor
// ============================================================================

access(all) fun testProjectedUserBalanceUsesProjectedSharePrice() {
    // Verify that getProjectedUserBalance still produces correct results
    // after being refactored to delegate to getProjectedSharePrice.
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Add unsync'd yield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: "testYieldVaultShort_")

    // Get projected balance and projected share price independently
    let balanceResult = getProjectedBalance(user.address, poolID)
    let projectedBalance = balanceResult["projectedBalance"]!
    let actualBalance = balanceResult["actualBalance"]!
    let shares = balanceResult["shares"]!

    let priceResult = getProjectedSharePrice(poolID)
    let projectedSharePrice = priceResult["projectedSharePrice"]!

    // Projected balance should equal shares * projected share price
    Test.assert(
        isWithinTolerance(projectedBalance, shares * projectedSharePrice, 0.00000002),
        message: "Projected balance should equal shares * projected share price. Balance: "
            .concat(projectedBalance.toString())
            .concat(", Shares * Price: ").concat((shares * projectedSharePrice).toString())
    )

    // Projected should be higher than actual
    Test.assert(
        projectedBalance > actualBalance,
        message: "Projected balance should be > actual with unsync'd yield"
    )

    // Sync and verify convergence
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedBalance(user.address, poolID)
    let projectedAfter = afterSync["projectedBalance"]!
    let actualAfter = afterSync["actualBalance"]!

    Test.assertEqual(projectedAfter, actualAfter)
}

// ============================================================================
// TEST: Projected Prize Pool with Direct Funding
// ============================================================================

access(all) fun testProjectedPrizePoolWithDirectFunding() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Directly fund the prize pool (this goes to allocatedPrizeYield, not the vault)
    fundPrizePool(poolID, amount: 50.0)

    // Synced should reflect the direct funding immediately
    let beforeYield = getProjectedPrizePoolBalance(poolID)
    let syncedBefore = beforeYield["syncedPrizePoolBalance"]!
    let projectedBefore = beforeYield["projectedPrizePoolBalance"]!

    // Direct funding is already in allocatedPrizeYield, so projected == synced
    Test.assertEqual(projectedBefore, syncedBefore)

    // Now add unsync'd yield on top
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: "testYieldVaultShort_")

    // Projected should now be higher (direct funding + projected yield portion)
    let afterYield = getProjectedPrizePoolBalance(poolID)
    let projectedAfter = afterYield["projectedPrizePoolBalance"]!
    let syncedAfter = afterYield["syncedPrizePoolBalance"]!

    Test.assert(
        projectedAfter > syncedAfter,
        message: "Projected should be > synced after unsync'd yield on top of direct funding. Projected: "
            .concat(projectedAfter.toString())
            .concat(", Synced: ").concat(syncedAfter.toString())
    )

    // Synced should still equal the direct funding amount (no yield synced yet)
    Test.assertEqual(syncedAfter, syncedBefore)
}
