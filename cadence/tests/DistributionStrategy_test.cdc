import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - FixedPercentageStrategy Creation
// ============================================================================

access(all) fun testFixedPercentage100Savings() {
    // Create pool with 100% savings, 0% lottery, 0% treasury
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, treasury: 0.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(1.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.0, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testFixedPercentage100Lottery() {
    // Create pool with 0% savings, 100% lottery, 0% treasury
    let poolID = createPoolWithDistribution(rewards: 0.0, prize: 1.0, treasury: 0.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(1.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.0, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testFixedPercentage100Treasury() {
    // Create pool with 0% savings, 0% lottery, 100% treasury
    let poolID = createPoolWithDistribution(rewards: 0.0, prize: 0.0, treasury: 1.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(1.0, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testFixedPercentageEqualSplit() {
    // Create pool with roughly equal split (must sum to 1.0)
    // Using 0.34 + 0.33 + 0.33 = 1.0
    let poolID = createPoolWithDistribution(rewards: 0.34, prize: 0.33, treasury: 0.33)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.34, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.33, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.33, details["treasuryPercent"]! as! UFix64)
}

access(all) fun testFixedPercentageCustomSplit() {
    // Create pool with 70/20/10 split (default in test pool)
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, treasury: 0.1)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.7, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.2, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.1, details["treasuryPercent"]! as! UFix64)
}

// ============================================================================
// TESTS - Distribution Calculation
// ============================================================================

access(all) fun testFixedPercentageCalculatesCorrectAmounts() {
    // With 70/20/10 split and 100.0 total:
    // savings = 70.0, lottery = 20.0, treasury = 10.0
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, treasury: 0.1)
    
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 100.0)
    Test.assertEqual(70.0, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(20.0, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(10.0, distribution["treasuryAmount"]! as! UFix64)
}

access(all) fun testDistributionWithZeroAmount() {
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, treasury: 0.1)
    
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 0.0)
    Test.assertEqual(0.0, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(0.0, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(0.0, distribution["treasuryAmount"]! as! UFix64)
}

access(all) fun testDistributionWithSmallAmount() {
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.3, treasury: 0.2)
    
    // With 1.0 total: savings = 0.5, lottery = 0.3, treasury = 0.2
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 1.0)
    Test.assertEqual(0.5, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(0.3, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(0.2, distribution["treasuryAmount"]! as! UFix64)
}

// ============================================================================
// TESTS - Strategy Name
// ============================================================================

access(all) fun testDistributionStrategyNameFormat() {
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, treasury: 0.1)
    
    let strategyName = getDistributionStrategyName(poolID: poolID)
    // Strategy name format: "Fixed: 0.70000000 savings, 0.20000000 lottery"
    Test.assert(strategyName.length > 0, message: "Strategy name should not be empty")
    Test.assert(strategyName.utf8.length > 5, message: "Strategy name should contain meaningful content")
}

// ============================================================================
// TESTS - Invalid Configurations (Failure Cases)
// ============================================================================

access(all) fun testDistributionStrategySumNotOneReverts() {
    // This test verifies that creating a strategy with sum != 1.0 fails
    // We expect the transaction to fail
    let result = createPoolWithDistributionExpectFailure(rewards: 0.5, prize: 0.3, treasury: 0.1)
    Test.assertEqual(false, result)
}

