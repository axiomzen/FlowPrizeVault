import Test
import "test_helpers.cdc"

// ============================================================================
// PROJECTED BALANCE TEST SUITE
// ============================================================================
//
// Tests for the projected user balance feature: view-only preview functions
// that calculate what a user's balance would be if syncWithYieldSource()
// were called right now. This enables real-time balance display without
// mutating contract state.
//
// Functions under test:
// - ShareTracker.previewAccrueYield()
// - Pool.previewDeficitImpactOnRewards()
// - Pool.getProjectedUserBalance()
// - PrizeLinkedAccounts.getProjectedUserBalance() (contract-level)
// ============================================================================

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Projected Balance Equals Actual When Synced
// ============================================================================

access(all) fun testProjectedEqualsActualWhenSynced() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // No unsync'd yield — projected should equal actual
    let result = getProjectedBalance(user.address, poolID)
    let projected = result["projectedBalance"]!
    let actual = result["actualBalance"]!

    Test.assertEqual(projected, actual)
}

// ============================================================================
// TEST: Projected Balance Reflects Unsync'd Yield
// ============================================================================

access(all) fun testProjectedReflectsUnsyncdYield() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate yield appreciation WITHOUT syncing
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: "testYieldVaultShort_")

    // Projected should be higher than actual (unsync'd yield)
    let beforeSync = getProjectedBalance(user.address, poolID)
    let projectedBefore = beforeSync["projectedBalance"]!
    let actualBefore = beforeSync["actualBalance"]!

    Test.assert(
        projectedBefore > actualBefore,
        message: "Projected should be > actual with unsync'd yield. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Actual: ").concat(actualBefore.toString())
    )

    // Now sync and verify they converge
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedBalance(user.address, poolID)
    let projectedAfter = afterSync["projectedBalance"]!
    let actualAfter = afterSync["actualBalance"]!

    Test.assertEqual(projectedAfter, actualAfter)

    // Actual after sync should match projected before sync
    Test.assert(
        isWithinTolerance(actualAfter, projectedBefore, 0.00000002),
        message: "Actual after sync should match projected before sync. Actual: "
            .concat(actualAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Projected Balance Reflects Deficit
// ============================================================================

access(all) fun testProjectedReflectsDeficit() {
    // Use custom distribution so we can reason about the waterfall
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate depreciation WITHOUT syncing
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 5.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected should be lower than actual (unsync'd deficit)
    let beforeSync = getProjectedBalance(user.address, poolID)
    let projectedBefore = beforeSync["projectedBalance"]!
    let actualBefore = beforeSync["actualBalance"]!

    Test.assert(
        projectedBefore < actualBefore,
        message: "Projected should be < actual with unsync'd deficit. Projected: "
            .concat(projectedBefore.toString())
            .concat(", Actual: ").concat(actualBefore.toString())
    )

    // Now sync and verify they converge
    triggerSyncWithYieldSource(poolID: poolID)

    let afterSync = getProjectedBalance(user.address, poolID)
    let projectedAfter = afterSync["projectedBalance"]!
    let actualAfter = afterSync["actualBalance"]!

    Test.assertEqual(projectedAfter, actualAfter)

    // Actual after sync should match projected before sync
    Test.assert(
        isWithinTolerance(actualAfter, projectedBefore, 0.00000002),
        message: "Actual after sync should match projected before sync. Actual: "
            .concat(actualAfter.toString())
            .concat(", Projected was: ").concat(projectedBefore.toString())
    )
}

// ============================================================================
// TEST: Zero Shares Returns Zero
// ============================================================================

access(all) fun testZeroSharesReturnsZero() {
    let poolID = createTestPoolWithShortInterval()

    // User with collection but no deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1.0)

    let result = getProjectedBalance(user.address, poolID)
    let projected = result["projectedBalance"]!

    Test.assertEqual(0.0, projected)
}

// ============================================================================
// TEST: Below-Threshold Difference Returns Actual
// ============================================================================

access(all) fun testBelowThresholdReturnsActual() {
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // The MINIMUM_DISTRIBUTION_THRESHOLD is 0.000001
    // With no yield manipulation, the difference should be 0 (below threshold)
    // Projected should exactly equal actual
    let result = getProjectedBalance(user.address, poolID)
    let projected = result["projectedBalance"]!
    let actual = result["actualBalance"]!

    Test.assertEqual(projected, actual)
}

// ============================================================================
// TEST: Preview Accrue Yield Matches Actual Accrual
// ============================================================================

access(all) fun testPreviewAccrueYieldMatchesActual() {
    // Verify that the projected balance before sync matches actual after sync.
    // This transitively proves previewAccrueYield matches accrueYield,
    // since the projected balance uses previewAccrueYield internally.
    let poolID = createTestPoolWithShortInterval()

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Add yield
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 50.0, vaultPrefix: "testYieldVaultShort_")

    // Get projected before sync
    let beforeSync = getProjectedBalance(user.address, poolID)
    let projectedBefore = beforeSync["projectedBalance"]!

    // Sync
    triggerSyncWithYieldSource(poolID: poolID)

    // Get actual after sync
    let afterSync = getUserActualBalance(user.address, poolID)
    let actualAfter = afterSync["actualBalance"]!

    // They should match (within UFix64 precision)
    Test.assert(
        isWithinTolerance(actualAfter, projectedBefore, 0.00000002),
        message: "previewAccrueYield result (via projected) should match accrueYield result (via actual). Projected: "
            .concat(projectedBefore.toString())
            .concat(", Actual: ").concat(actualAfter.toString())
    )
}

// ============================================================================
// TEST: Deficit Waterfall — Protocol Absorbs First
// ============================================================================

access(all) fun testDeficitWaterfallProtocolAbsorbsFirst() {
    // Create pool with protocol fee allocation, add yield to build up buckets,
    // then verify small deficit doesn't affect user balance.
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.2, protocolFee: 0.3)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // First, add yield and sync to build up protocol fee and prize allocations
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)

    // Check allocations after sync
    let rewardsInfo = getPoolRewardsInfo(poolID)
    let allocatedProtocolFee = rewardsInfo["allocatedProtocolFee"]!
    let allocatedPrizeYield = rewardsInfo["allocatedPrizeYield"]!

    Test.assert(allocatedProtocolFee > 0.0, message: "Should have protocol fee allocation")
    Test.assert(allocatedPrizeYield > 0.0, message: "Should have prize yield allocation")

    // Record user's actual balance after the yield sync
    let balanceAfterYield = getUserActualBalance(user.address, poolID)
    let actualAfterYield = balanceAfterYield["actualBalance"]!

    // Now simulate a small deficit that fits within protocol fee allocation
    let smallDeficit = allocatedProtocolFee * 0.5  // Half the protocol fee
    simulateYieldDepreciation(poolIndex: poolIndex, amount: smallDeficit, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Projected balance should equal actual — deficit absorbed by protocol fee
    let result = getProjectedBalance(user.address, poolID)
    let projected = result["projectedBalance"]!

    Test.assert(
        isWithinTolerance(projected, actualAfterYield, 0.00000002),
        message: "Small deficit should be absorbed by protocol fee, not affecting user balance. Projected: "
            .concat(projected.toString())
            .concat(", Balance after yield: ").concat(actualAfterYield.toString())
    )
}
