import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// TEST ACCOUNTS
// ============================================================================

access(all) let depositUserAccount = Test.createAccount()

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Deposits
// ============================================================================

access(all) fun testUserDepositIncreasesPoolTotals() {
    let poolID: UInt64 = 0
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    
    ensurePoolExists()
    
    let initialTotals = getPoolTotals(poolID)
    let initialStaked = initialTotals["userPoolBalance"]!
    
    // Setup user and deposit
    setupUserWithFundsAndCollection(depositUserAccount, amount: depositAmount + 1.0)
    depositToPool(depositUserAccount, poolID: poolID, amount: depositAmount)
    
    // Verify pool totals increased
    let finalTotals = getPoolTotals(poolID)
    Test.assertEqual(initialStaked + depositAmount, finalTotals["userPoolBalance"]!)
}

access(all) fun testUserDepositUpdatesUserBalance() {
    let poolID: UInt64 = 0
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    
    ensurePoolExists()
    
    // Create new user for clean state
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Verify user's balance
    let userBalance = getUserPoolBalance(newUser.address, poolID)
    Test.assertEqual(depositAmount, userBalance["totalBalance"]!)
    Test.assertEqual(0.0, userBalance["totalEarnedPrizes"]!)
}

access(all) fun testMultipleDepositsAccumulate() {
    let poolID: UInt64 = 0
    let firstDeposit: UFix64 = 5.0
    let secondDeposit: UFix64 = 10.0
    
    ensurePoolExists()
    
    // Create new user
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: firstDeposit + secondDeposit + 2.0)
    
    // Make two deposits
    depositToPool(newUser, poolID: poolID, amount: firstDeposit)
    depositToPool(newUser, poolID: poolID, amount: secondDeposit)
    
    // Verify accumulated balance
    let userBalance = getUserPoolBalance(newUser.address, poolID)
    Test.assertEqual(firstDeposit + secondDeposit, userBalance["totalBalance"]!)
}

access(all) fun testMultipleUsersCanDeposit() {
    let poolID: UInt64 = 0
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    
    ensurePoolExists()
    
    let initialTotals = getPoolTotals(poolID)
    let initialStaked = initialTotals["userPoolBalance"]!
    
    // Create multiple users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 1.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 1.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Verify pool totals include both deposits
    let finalTotals = getPoolTotals(poolID)
    Test.assertEqual(initialStaked + (depositAmount * 2.0), finalTotals["userPoolBalance"]!)
    
    // Verify each user has correct balance
    let user1Balance = getUserPoolBalance(user1.address, poolID)
    let user2Balance = getUserPoolBalance(user2.address, poolID)
    Test.assertEqual(depositAmount, user1Balance["totalBalance"]!)
    Test.assertEqual(depositAmount, user2Balance["totalBalance"]!)
}

// ============================================================================
// TESTS - Withdrawals (placeholder for future implementation)
// ============================================================================

// TODO: Add withdrawal tests when withdrawal functionality is ready
// - testUserCanWithdrawDeposits
// - testUserCannotWithdrawMoreThanBalance
// - testWithdrawUpdatesPoolTotals
// - testPartialWithdraw

