import Test
import "PrizeSavings"
import "test_helpers.cdc"

/// Tests for deposit capacity overflow protection
/// Verifies that transactions revert when yield connector can't accept full deposit

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Creates a pool with limited capacity connector
access(all) fun createLimitedCapacityPool(capacityLimit: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_limited_capacity.cdc",
        [capacityLimit],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create limited capacity pool")
    return UInt64(getPoolCount() - 1)
}

/// Attempts a deposit and expects it to fail
access(all) fun depositExpectFailure(user: Test.TestAccount, poolID: UInt64, amount: UFix64): Test.TransactionResult {
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("../transactions/test/deposit_to_pool.cdc"),
            authorizers: [user.address],
            signers: [user],
            arguments: [poolID, amount]
        )
    )
    return result
}

// ============================================================================
// TEST: User Deposit Capacity Overflow
// ============================================================================

access(all) fun testDepositFailsWhenCapacityExceeded() {
    // Create pool with capacity limit of 50 tokens
    let capacityLimit: UFix64 = 50.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    // Create user with 100 tokens
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 100.0)
    
    // Attempt to deposit 60 tokens (exceeds 50 capacity limit)
    let depositAmount: UFix64 = 60.0
    let result = depositExpectFailure(user: user, poolID: poolID, amount: depositAmount)
    
    // Verify transaction failed
    Test.assertEqual(Test.ResultStatus.failed, result.status)
    
    // Verify error message contains capacity exceeded info
    let errorMessage = result.error!.message
    Test.assert(
        errorMessage.toLower().contains("capacity") || errorMessage.toLower().contains("leftover"),
        message: "Error should mention capacity exceeded. Got: ".concat(errorMessage)
    )
    
    log("Test passed: Deposit correctly rejected when capacity exceeded")
}

access(all) fun testDepositSucceedsWithinCapacity() {
    // Create pool with capacity limit of 100 tokens
    let capacityLimit: UFix64 = 100.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    // Create user with 50 tokens
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 60.0)
    
    // Deposit 50 tokens (within 100 capacity limit)
    let depositAmount: UFix64 = 50.0
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Verify deposit succeeded by checking pool totals
    let poolTotals = getPoolTotals(poolID)
    Test.assertEqual(depositAmount, poolTotals["totalStaked"]!)
    
    log("Test passed: Deposit succeeded within capacity limit")
}

access(all) fun testDepositExactlyAtCapacitySucceeds() {
    // Create pool with capacity limit of 50 tokens
    let capacityLimit: UFix64 = 50.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    // Create user and deposit exactly at capacity
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 60.0)
    
    // Deposit of exactly 50 (at capacity limit) should work
    depositToPool(user, poolID: poolID, amount: 50.0)
    
    // Verify deposit succeeded by checking pool totals
    let poolTotals = getPoolTotals(poolID)
    Test.assertEqual(50.0, poolTotals["totalStaked"]!)
    
    log("Test passed: Deposit exactly at capacity limit succeeded")
}

access(all) fun testSponsorDepositFailsWhenCapacityExceeded() {
    // Create pool with capacity limit of 50 tokens
    let capacityLimit: UFix64 = 50.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    // Create sponsor with 100 tokens
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: 100.0)
    
    // Attempt sponsor deposit of 60 tokens (exceeds capacity)
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("../transactions/prize-savings/sponsor_deposit.cdc"),
            authorizers: [sponsor.address],
            signers: [sponsor],
            arguments: [poolID, 60.0]
        )
    )
    
    // Should fail
    Test.assertEqual(Test.ResultStatus.failed, result.status)
    
    log("Test passed: Sponsor deposit correctly rejected when capacity exceeded")
}

access(all) fun testZeroCapacityRejectsAllDeposits() {
    // Create pool with zero capacity
    let capacityLimit: UFix64 = 0.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    // Create user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 20.0)
    
    // Any deposit should fail
    let result = depositExpectFailure(user: user, poolID: poolID, amount: 10.0)
    
    Test.assertEqual(Test.ResultStatus.failed, result.status)
    
    log("Test passed: Zero capacity connector rejects all deposits")
}

access(all) fun testPartialCapacityRemainsUndeposited() {
    // This test verifies the error message includes correct amounts
    let capacityLimit: UFix64 = 30.0
    let poolID = createLimitedCapacityPool(capacityLimit: capacityLimit)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 100.0)
    
    // Attempt to deposit 50 tokens, but only 30 can be accepted
    let result = depositExpectFailure(user: user, poolID: poolID, amount: 50.0)
    
    Test.assertEqual(Test.ResultStatus.failed, result.status)
    
    // The error should mention leftover amount (50 - 30 = 20)
    let errorMessage = result.error!.message
    Test.assert(
        errorMessage.contains("leftover") || errorMessage.contains("20"),
        message: "Error should show leftover amount. Got: ".concat(errorMessage)
    )
    
    log("Test passed: Error message correctly shows leftover amount")
}


