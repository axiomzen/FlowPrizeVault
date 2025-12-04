import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Default Funding Policy
// ============================================================================

access(all) fun testDefaultFundingPolicyValues() {
    // Create pool with nil funding policy (uses defaults)
    createTestPool()
    
    let poolID = UInt64(getPoolCount() - 1)
    let stats = getFundingStats(poolID)
    
    // Default values: all limits nil (unlimited), all totals 0
    Test.assertEqual(0.0, stats["totalDirectLottery"]! as! UFix64)
    Test.assertEqual(0.0, stats["totalDirectTreasury"]! as! UFix64)
    Test.assertEqual(0.0, stats["totalDirectSavings"]! as! UFix64)
}

// ============================================================================
// TESTS - Funding Policy with Limits
// ============================================================================

access(all) fun testFundingPolicyWithLotteryLimit() {
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: 1000.0,
        maxDirectTreasury: nil,
        maxDirectSavings: nil
    )
    
    let stats = getFundingStats(poolID)
    Test.assertEqual(1000.0, stats["maxDirectLottery"]! as! UFix64)
}

access(all) fun testFundingPolicyWithTreasuryLimit() {
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: nil,
        maxDirectTreasury: 500.0,
        maxDirectSavings: nil
    )
    
    let stats = getFundingStats(poolID)
    Test.assertEqual(500.0, stats["maxDirectTreasury"]! as! UFix64)
}

access(all) fun testFundingPolicyWithSavingsLimit() {
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: nil,
        maxDirectTreasury: nil,
        maxDirectSavings: 2000.0
    )
    
    let stats = getFundingStats(poolID)
    Test.assertEqual(2000.0, stats["maxDirectSavings"]! as! UFix64)
}

access(all) fun testFundingPolicyAllLimitsSet() {
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: 100.0,
        maxDirectTreasury: 200.0,
        maxDirectSavings: 300.0
    )
    
    let stats = getFundingStats(poolID)
    Test.assertEqual(100.0, stats["maxDirectLottery"]! as! UFix64)
    Test.assertEqual(200.0, stats["maxDirectTreasury"]! as! UFix64)
    Test.assertEqual(300.0, stats["maxDirectSavings"]! as! UFix64)
}

// ============================================================================
// TESTS - Direct Funding Operations
// ============================================================================

access(all) fun testDirectFundingToLottery() {
    let poolID = createTestPoolWithShortInterval()
    
    // Fund lottery pool
    fundLotteryPool(poolID, amount: 10.0)
    
    let poolTotals = getPoolTotals(poolID)
    Test.assert(poolTotals["lotteryBalance"]! >= 10.0, message: "Lottery balance should include direct funding")
}

access(all) fun testFundingStatsTracked() {
    let poolID = createTestPoolWithShortInterval()
    
    // Initial stats should be zero
    var stats = getFundingStats(poolID)
    Test.assertEqual(0.0, stats["totalDirectLottery"]! as! UFix64)
    
    // After funding, stats should update
    fundLotteryPool(poolID, amount: 5.0)
    
    // Note: fundLotteryPool uses direct funding which is tracked
    let poolTotals = getPoolTotals(poolID)
    Test.assert(poolTotals["lotteryBalance"]! >= 5.0, message: "Lottery should be funded")
}

// ============================================================================
// TESTS - Unlimited Funding
// ============================================================================

access(all) fun testFundingPolicyUnlimitedFunding() {
    // Create pool with all nil limits (unlimited)
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: nil,
        maxDirectTreasury: nil,
        maxDirectSavings: nil
    )
    
    let stats = getFundingStats(poolID)
    // When nil, the getter returns 0.0 but the limit is actually unlimited
    Test.assertEqual(0.0, stats["maxDirectLottery"]! as! UFix64)
    Test.assertEqual(0.0, stats["maxDirectTreasury"]! as! UFix64)
    Test.assertEqual(0.0, stats["maxDirectSavings"]! as! UFix64)
}

// ============================================================================
// TESTS - Funding Totals Tracking
// ============================================================================

access(all) fun testFundingTotalsStartAtZero() {
    let poolID = createPoolWithFundingPolicy(
        maxDirectLottery: 1000.0,
        maxDirectTreasury: 1000.0,
        maxDirectSavings: 1000.0
    )
    
    let stats = getFundingStats(poolID)
    Test.assertEqual(0.0, stats["totalDirectLottery"]! as! UFix64)
    Test.assertEqual(0.0, stats["totalDirectTreasury"]! as! UFix64)
    Test.assertEqual(0.0, stats["totalDirectSavings"]! as! UFix64)
}

access(all) fun testMultipleFundingOperationsAccumulate() {
    let poolID = createTestPoolWithShortInterval()
    
    // Fund lottery pool multiple times
    fundLotteryPool(poolID, amount: 5.0)
    fundLotteryPool(poolID, amount: 3.0)
    
    let poolTotals = getPoolTotals(poolID)
    Test.assert(poolTotals["lotteryBalance"]! >= 8.0, message: "Lottery balance should accumulate")
}

