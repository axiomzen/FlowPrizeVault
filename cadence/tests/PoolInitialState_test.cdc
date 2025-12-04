import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Emergency State
// ============================================================================

access(all) fun testNewPoolEmergencyStateNormal() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolEmergencyState(poolID)
    Test.assertEqual(UInt8(0), state)  // Normal = 0
}

// ============================================================================
// TESTS - Balance Tracking
// ============================================================================

access(all) fun testNewPoolTotalDepositedZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalDeposited"]! as! UFix64)
}

access(all) fun testNewPoolTotalStakedZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalStaked"]! as! UFix64)
}

access(all) fun testNewPoolLastDrawTimestampZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["lastDrawTimestamp"]! as! UFix64)
}

access(all) fun testNewPoolPendingLotteryYieldZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["pendingLotteryYield"]! as! UFix64)
}

// ============================================================================
// TESTS - Receiver Registration
// ============================================================================

access(all) fun testNewPoolNoRegisteredReceivers() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0, state["registeredReceiverCount"]! as! Int)
}

// ============================================================================
// TESTS - Draw State
// ============================================================================

access(all) fun testNewPoolDrawNotInProgress() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(false, state["isDrawInProgress"]! as! Bool)
}

access(all) fun testNewPoolCanDrawNowTrue() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    // With lastDrawTimestamp = 0 and current timestamp > 0, canDrawNow should be true
    Test.assertEqual(true, state["canDrawNow"]! as! Bool)
}

// ============================================================================
// TESTS - Pool Balances
// ============================================================================

access(all) fun testNewPoolLotteryBalanceZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["lotteryPoolBalance"]! as! UFix64)
}

access(all) fun testNewPoolTreasuryForwardedZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalTreasuryForwarded"]! as! UFix64)
}

// ============================================================================
// TESTS - Savings Distributor State
// ============================================================================

access(all) fun testNewPoolSharePriceOne() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(true, state["sharePriceIsOne"]! as! Bool)
}

access(all) fun testNewPoolEpochIDOne() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(1), state["currentEpochID"]! as! UInt64)
}

access(all) fun testNewPoolTotalSavingsSharesZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalSavingsShares"]! as! UFix64)
}

access(all) fun testNewPoolTotalSavingsAssetsZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalSavingsAssets"]! as! UFix64)
}

access(all) fun testNewPoolTotalSavingsDistributedZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["totalSavingsDistributed"]! as! UFix64)
}

access(all) fun testNewPoolCurrentReinvestedSavingsZero() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(0.0, state["currentReinvestedSavings"]! as! UFix64)
}

