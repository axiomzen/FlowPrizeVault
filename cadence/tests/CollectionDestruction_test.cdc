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
// HELPERS
// ============================================================================

access(all)
fun destroyCollection(_ account: Test.TestAccount) {
    let result = _executeTransaction(
        "../transactions/test/destroy_collection.cdc",
        [],
        account
    )
    assertTransactionSucceeded(result, context: "Destroy collection")
}

// ============================================================================
// TESTS
// ============================================================================

access(all) fun testDestroyEmptyCollectionIsHarmless() {
    let user = Test.createAccount()
    setupPoolPositionCollection(user)

    destroyCollection(user)
}

access(all) fun testDestroyCollectionWithActiveBalance_SharesOrphaned() {
    let poolID = createTestPoolWithMediumInterval()
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let beforeShares = getPoolShares(poolID)

    destroyCollection(user)

    let afterShares = getPoolShares(poolID)
    Test.assertEqual(beforeShares, afterShares)

    // getUserPoolBalance borrows the public capability which no longer exists
    let balanceResult = _executeScript(
        "../scripts/test/get_user_pool_balance.cdc",
        [user.address, poolID]
    )
    Test.expect(balanceResult, Test.beFailed())
}

access(all) fun testDestroyCollectionWithActiveBalance_PoolIntegrityPreserved() {
    let poolID = createTestPoolWithMediumInterval()

    let userA = Test.createAccount()
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(userB, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(userA, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(userB, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let beforeShares = getPoolShares(poolID)

    destroyCollection(userA)

    let afterShares = getPoolShares(poolID)
    Test.assertEqual(beforeShares, afterShares)

    // User B's shares are still half the total
    let userBBalance = getUserPoolBalance(userB.address, poolID)
    Test.assert(userBBalance["totalBalance"]! > 0.0, message: "User B balance should still be tracked")

    // Draw completes without panic even though user A's UUID is still in the batch
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(userB, poolID: poolID)

    // User B's position is still readable after the draw
    let userBBalanceAfter = getUserPoolBalance(userB.address, poolID)
    Test.assert(userBBalanceAfter["totalBalance"]! > 0.0, message: "User B balance should remain accessible after draw")
}

access(all) fun testDestroyCollectionWithPendingPrize() {
    let poolID = createTestPoolWithMediumInterval()
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Run a full draw so the user wins (sole participant)
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDrawWithIntermission(user, poolID: poolID)

    // Prize is reinvested — user's balance grew
    let balanceAfterWin = getUserPoolBalance(user.address, poolID)
    Test.assert(
        balanceAfterWin["totalBalance"]! > DEFAULT_DEPOSIT_AMOUNT,
        message: "User balance should reflect won prize"
    )

    let beforeShares = getPoolShares(poolID)

    destroyCollection(user)

    // Pool-side share accounting is unchanged; prize value is now orphaned
    let afterShares = getPoolShares(poolID)
    Test.assertEqual(beforeShares, afterShares)
}
