import Test
import "PrizeLinkedAccounts"
import "test_helpers.cdc"

// ============================================================================
// TEST ACCOUNTS
// ============================================================================

access(all) let collectionUserAccount = Test.createAccount()

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Collection Creation
// ============================================================================

access(all) fun testCreateEmptyPoolPositionCollection() {
    let collection <- PrizeLinkedAccounts.createPoolPositionCollection()
    
    let registeredPools = collection.getRegisteredPoolIDs()
    Test.assertEqual(0, registeredPools.length)
    
    destroy collection
}

access(all) fun testSetupUserCollection() {
    setupPoolPositionCollection(collectionUserAccount)
    
    // Verify collection exists by checking user can interact with a pool
    // If setup failed, subsequent operations would fail
    ensurePoolExists()
    fundAccountWithFlow(collectionUserAccount, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(collectionUserAccount, poolID: 0, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // If we get here without error, collection was successfully set up
    let balance = getUserPoolBalance(collectionUserAccount.address, 0)
    Test.assert(balance["totalBalance"]! > 0.0, message: "Collection should be functional after setup")
}

// ============================================================================
// TESTS - Collection Registration
// ============================================================================

access(all) fun testCollectionRegistersPoolOnDeposit() {
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    let poolID: UInt64 = 0
    
    // Ensure pool exists
    ensurePoolExists()
    
    // Create new user for this test
    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)
    
    // Deposit should register the pool in user's collection
    depositToPool(newUser, poolID: poolID, amount: depositAmount)
    
    // Verify the pool is now registered
    let userBalance = getUserPoolBalance(newUser.address, poolID)
    Test.assertEqual(depositAmount, userBalance["totalBalance"]!)
}

