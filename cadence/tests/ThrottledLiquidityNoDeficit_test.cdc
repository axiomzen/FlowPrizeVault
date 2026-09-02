import Test
import "test_helpers.cdc"

// ============================================================================
// Regression tests: a throttled yield-source exit must not be booked as a loss.
//
// A yield source can hold the pool's full position while allowing only a
// fraction of it to be withdrawn at any given moment -- e.g. a Morpho Vault V2
// whose curator has cleared the liquidity adapter, leaving redemptions served
// from idle balance only.
//
// In that state minimumAvailable() (withdrawable now) falls far below the
// position's NAV. Marking solvency against the withdrawable figure treats the
// gap as a realised loss and socialises it across every depositor's share
// price. Solvency must be marked against NAV instead; the withdrawable figure
// remains correct for liquidity guards.
// ============================================================================

access(all) let VAULT_PREFIX = "testYieldVaultThrottled_"
access(all) let TOLERANCE = 0.0001

access(all) fun setup() {
    deployAllDependencies()
}

/// The core regression: deposit 100 into a source that will only let 10 out,
/// then reconcile. Share price must not move.
access(all) fun testThrottledExitDoesNotCreateDeficit() {
    // liquidityCap 10.0 vs a 100.0 position => withdrawable is 10% of NAV
    let poolID = createPoolWithThrottledConnector(
        rewards: 0.35, prize: 0.65, protocolFee: 0.0, liquidityCap: 10.0
    )
    let poolIndex = Int(poolID)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    let before = getPoolRewardsInfo(poolID)
    Test.assert(
        isWithinTolerance(before["sharePrice"]!, 1.0, TOLERANCE),
        message: "Share price should start at ~1.0. Got: ".concat(before["sharePrice"]!.toString())
    )

    // The whole position is present in the yield vault; only the exit is throttled.
    Test.assert(
        isWithinTolerance(getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX), 100.0, TOLERANCE),
        message: "Yield vault should hold the full 100.0 position"
    )

    // Reconcile. Marking against the withdrawable figure would book a ~90.0
    // deficit here and crash the share price to ~0.1.
    triggerSyncWithYieldSource(poolID: poolID)

    let after = getPoolRewardsInfo(poolID)
    Test.assert(
        isWithinTolerance(after["sharePrice"]!, 1.0, TOLERANCE),
        message: "Throttled exit must not move share price. Got: ".concat(after["sharePrice"]!.toString())
    )
    Test.assert(
        isWithinTolerance(after["totalAssets"]!, 100.0, TOLERANCE),
        message: "Total assets must still equal NAV. Got: ".concat(after["totalAssets"]!.toString())
    )
}

/// A user's reported balance must reflect what they own, not what could be
/// liquidated this instant -- this is the figure the API renders.
access(all) fun testThrottledExitDoesNotShrinkUserBalance() {
    let poolID = createPoolWithThrottledConnector(
        rewards: 0.35, prize: 0.65, protocolFee: 0.0, liquidityCap: 10.0
    )

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    triggerSyncWithYieldSource(poolID: poolID)

    let projected = getProjectedBalance(user.address, poolID)
    let projectedBalance = projected["projectedBalance"] ?? projected["balance"] ?? 0.0
    Test.assert(
        isWithinTolerance(projectedBalance, 100.0, TOLERANCE),
        message: "Projected balance must track NAV, not withdrawable. Got: ".concat(projectedBalance.toString())
    )
}

/// Real appreciation must still be detected and split while the exit is throttled.
access(all) fun testRealYieldStillAccruesWhileExitThrottled() {
    let poolID = createPoolWithThrottledConnector(
        rewards: 0.35, prize: 0.65, protocolFee: 0.0, liquidityCap: 10.0
    )
    let poolIndex = Int(poolID)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    triggerSyncWithYieldSource(poolID: poolID)

    // 10.0 of genuine appreciation, split 35/65
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX)
    triggerSyncWithYieldSource(poolID: poolID)

    let after = getPoolRewardsInfo(poolID)
    Test.assert(
        isWithinTolerance(after["totalAssets"]!, 103.5, 0.01),
        message: "Rewards should take 35% of 10.0 => 103.5. Got: ".concat(after["totalAssets"]!.toString())
    )
    Test.assert(
        isWithinTolerance(after["allocatedPrizeYield"]!, 6.5, 0.01),
        message: "Prize should take 65% of 10.0 => 6.5. Got: ".concat(after["allocatedPrizeYield"]!.toString())
    )
}

/// A genuine loss must still be socialised: the fix must not mask real impairment.
access(all) fun testGenuineLossStillAppliesWhileExitThrottled() {
    let poolID = createPoolWithThrottledConnector(
        rewards: 0.35, prize: 0.65, protocolFee: 0.0, liquidityCap: 10.0
    )
    let poolIndex = Int(poolID)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    triggerSyncWithYieldSource(poolID: poolID)

    // Funds genuinely leave the yield vault: NAV itself drops to 80.0.
    simulateYieldDepreciation(poolIndex: poolIndex, amount: 20.0, vaultPrefix: VAULT_PREFIX)
    triggerSyncWithYieldSource(poolID: poolID)

    let after = getPoolRewardsInfo(poolID)
    Test.assert(
        isWithinTolerance(after["totalAssets"]!, 80.0, 0.01),
        message: "A real 20.0 loss must still be applied. Got: ".concat(after["totalAssets"]!.toString())
    )
    Test.assert(
        after["sharePrice"]! < 1.0,
        message: "Share price must fall on a real loss. Got: ".concat(after["sharePrice"]!.toString())
    )
}
