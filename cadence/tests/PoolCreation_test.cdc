import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Pool Access
// ============================================================================

access(all) fun testGetAllPoolIDsReturnsCreatedPools() {
    let initialPoolIDs = getAllPoolIDs()
    let initialCount = initialPoolIDs.length
    
    createTestPool()
    createTestPool()
    
    let finalPoolIDs = getAllPoolIDs()
    Test.assertEqual(initialCount + 2, finalPoolIDs.length)
}

access(all) fun testBorrowExistingPool() {
    ensurePoolExists()
    
    let exists = poolExists(0)
    Test.assert(exists, message: "Pool 0 should exist after creation")
}

access(all) fun testBorrowNonExistentPoolReturnsNil() {
    let exists = poolExists(999)
    Test.assert(!exists, message: "Pool 999 should not exist")
}

// ============================================================================
// TESTS - Pool Creation
// ============================================================================

access(all) fun testCreatePoolAndVerifyCount() {
    let initialPoolCount = getPoolCount()
    
    createTestPool()
    
    let finalPoolCount = getPoolCount()
    Test.assertEqual(initialPoolCount + 1, finalPoolCount)
}

access(all) fun testCreatePoolWithCorrectConfiguration() {
    createTestPool()
    
    let poolCount = getPoolCount()
    let poolID = UInt64(poolCount - 1)
    
    let poolDetails = getPoolDetails(poolID)
    Test.assertEqual(DEFAULT_MINIMUM_DEPOSIT, poolDetails["minimumDeposit"]! as! UFix64)
    Test.assertEqual(DEFAULT_DRAW_INTERVAL, poolDetails["drawIntervalSeconds"]! as! UFix64)
}

access(all) fun testCreatePoolWithShortInterval() {
    let poolID = createTestPoolWithShortInterval()
    
    let poolDetails = getPoolDetails(poolID)
    Test.assertEqual(SHORT_DRAW_INTERVAL, poolDetails["drawIntervalSeconds"]! as! UFix64)
}

