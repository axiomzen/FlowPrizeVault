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
    Test.assertEqual(0.0, state["allocatedSavings"]! as! UFix64)
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
    Test.assertEqual(0.0, state["allocatedLotteryYield"]! as! UFix64)
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

access(all) fun testNewPoolCanDrawNowFalse() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    // New pools can't draw until the first round ends (round-based TWAB)
    Test.assertEqual(false, state["canDrawNow"]! as! Bool)
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
// TESTS - Share Tracker State
// ============================================================================

access(all) fun testNewPoolSharePriceOne() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(true, state["sharePriceIsOne"]! as! Bool)
}

access(all) fun testNewPoolRoundIDOne() {
    createTestPool()
    let poolID = UInt64(getPoolCount() - 1)
    
    let state = getPoolInitialState(poolID)
    Test.assertEqual(UInt64(1), state["currentRoundID"]! as! UInt64)
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

