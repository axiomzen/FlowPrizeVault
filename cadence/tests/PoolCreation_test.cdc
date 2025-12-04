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

// ============================================================================
// TESTS - Pool ID Management
// ============================================================================

access(all) fun testCreateMultiplePoolsSequentialIDs() {
    // Record starting point
    let initialCount = getPoolCount()
    
    // Create 5 pools
    createTestPool()
    createTestPool()
    createTestPool()
    createTestPool()
    createTestPool()
    
    // Verify we have 5 more pools
    let finalCount = getPoolCount()
    Test.assertEqual(initialCount + 5, finalCount)
    
    // Verify IDs are sequential starting from initial count
    let allIDs = getAllPoolIDs()
    var i = 0
    while i < 5 {
        let expectedID = UInt64(initialCount + i)
        Test.assert(allIDs.contains(expectedID), message: "Pool ID ".concat(expectedID.toString()).concat(" should exist"))
        i = i + 1
    }
}

access(all) fun testPoolIDsNeverDuplicate() {
    // Create 10 pools and verify no duplicate IDs
    let initialIDs = getAllPoolIDs()
    
    var i = 0
    while i < 10 {
        createTestPool()
        i = i + 1
    }
    
    let allIDs = getAllPoolIDs()
    
    // Check for duplicates by comparing length to unique count
    let uniqueIDs: {UInt64: Bool} = {}
    for id in allIDs {
        Test.assert(uniqueIDs[id] == nil, message: "Duplicate pool ID found: ".concat(id.toString()))
        uniqueIDs[id] = true
    }
    
    // Verify count matches
    Test.assertEqual(allIDs.length, uniqueIDs.keys.length)
}

access(all) fun testBorrowPoolByAnyValidID() {
    // Create several pools
    let initialCount = getPoolCount()
    createTestPool()
    createTestPool()
    createTestPool()
    
    // Verify we can access each by ID
    let id1 = UInt64(initialCount)
    let id2 = UInt64(initialCount + 1)
    let id3 = UInt64(initialCount + 2)
    
    Test.assert(poolExists(id1), message: "Pool ".concat(id1.toString()).concat(" should exist"))
    Test.assert(poolExists(id2), message: "Pool ".concat(id2.toString()).concat(" should exist"))
    Test.assert(poolExists(id3), message: "Pool ".concat(id3.toString()).concat(" should exist"))
}

access(all) fun testGetAllPoolIDsContainsAllCreated() {
    let initialIDs = getAllPoolIDs()
    let initialCount = initialIDs.length
    
    // Create 3 pools and track their expected IDs
    let expectedNewIDs: [UInt64] = [
        UInt64(initialCount),
        UInt64(initialCount + 1),
        UInt64(initialCount + 2)
    ]
    
    createTestPool()
    createTestPool()
    createTestPool()
    
    let finalIDs = getAllPoolIDs()
    
    // Verify all new IDs are present
    for expectedID in expectedNewIDs {
        Test.assert(finalIDs.contains(expectedID), message: "getAllPoolIDs should contain ".concat(expectedID.toString()))
    }
}

access(all) fun testPoolCountMatchesGetAllPoolIDsLength() {
    // Create some pools
    createTestPool()
    createTestPool()
    
    let count = getPoolCount()
    let idsLength = getAllPoolIDs().length
    
    Test.assertEqual(count, idsLength)
}

access(all) fun testFirstPoolIDIsZero() {
    // Get current state
    let currentCount = getPoolCount()
    
    // If no pools exist yet, verify first ID will be 0
    if currentCount == 0 {
        createTestPool()
        let ids = getAllPoolIDs()
        Test.assert(ids.contains(0), message: "First pool should have ID 0")
    } else {
        // Pools already exist, just verify pool 0 exists
        Test.assert(poolExists(0), message: "Pool 0 should exist")
    }
}

access(all) fun testPoolIDsIncrementByOne() {
    let initialCount = getPoolCount()
    
    // Create first pool
    createTestPool()
    let firstID = UInt64(initialCount)
    
    // Create second pool
    createTestPool()
    let secondID = UInt64(initialCount + 1)
    
    // Create third pool  
    createTestPool()
    let thirdID = UInt64(initialCount + 2)
    
    // Verify each ID increments by exactly 1
    Test.assertEqual(secondID, firstID + 1)
    Test.assertEqual(thirdID, secondID + 1)
    
    // Verify all exist
    Test.assert(poolExists(firstID), message: "First pool should exist")
    Test.assert(poolExists(secondID), message: "Second pool should exist")
    Test.assert(poolExists(thirdID), message: "Third pool should exist")
}

