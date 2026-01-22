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

access(all) fun testFixedPercentage100Rewards() {
    // Create pool with 100% rewards, 0% prize, 0% protocol
    let poolID = createPoolWithDistribution(rewards: 1.0, prize: 0.0, protocolFee: 0.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(1.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.0, details["protocolFeePercent"]! as! UFix64)
}

access(all) fun testFixedPercentage100Prize() {
    // Create pool with 0% rewards, 100% prize, 0% protocol
    let poolID = createPoolWithDistribution(rewards: 0.0, prize: 1.0, protocolFee: 0.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(1.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.0, details["protocolFeePercent"]! as! UFix64)
}

access(all) fun testFixedPercentage100Protocol() {
    // Create pool with 0% rewards, 0% prize, 100% protocol
    let poolID = createPoolWithDistribution(rewards: 0.0, prize: 0.0, protocolFee: 1.0)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.0, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.0, details["prizePercent"]! as! UFix64)
    Test.assertEqual(1.0, details["protocolFeePercent"]! as! UFix64)
}

access(all) fun testFixedPercentageEqualSplit() {
    // Create pool with roughly equal split (must sum to 1.0)
    // Using 0.34 + 0.33 + 0.33 = 1.0
    let poolID = createPoolWithDistribution(rewards: 0.34, prize: 0.33, protocolFee: 0.33)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.34, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.33, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.33, details["protocolFeePercent"]! as! UFix64)
}

access(all) fun testFixedPercentageCustomSplit() {
    // Create pool with 70/20/10 split (default in test pool)
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    let details = getPoolDistributionDetails(poolID)
    Test.assertEqual(0.7, details["rewardsPercent"]! as! UFix64)
    Test.assertEqual(0.2, details["prizePercent"]! as! UFix64)
    Test.assertEqual(0.1, details["protocolFeePercent"]! as! UFix64)
}

// ============================================================================
// TESTS - Distribution Calculation
// ============================================================================

access(all) fun testFixedPercentageCalculatesCorrectAmounts() {
    // With 70/20/10 split and 100.0 total:
    // rewards = 70.0, prize = 20.0, protocol = 10.0
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 100.0)
    Test.assertEqual(70.0, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(20.0, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(10.0, distribution["protocolFeeAmount"]! as! UFix64)
}

access(all) fun testDistributionWithZeroAmount() {
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 0.0)
    Test.assertEqual(0.0, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(0.0, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(0.0, distribution["protocolFeeAmount"]! as! UFix64)
}

access(all) fun testDistributionWithSmallAmount() {
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.3, protocolFee: 0.2)
    
    // With 1.0 total: rewards = 0.5, prize = 0.3, protocol = 0.2
    let distribution = calculateDistribution(poolID: poolID, totalAmount: 1.0)
    Test.assertEqual(0.5, distribution["rewardsAmount"]! as! UFix64)
    Test.assertEqual(0.3, distribution["prizeAmount"]! as! UFix64)
    Test.assertEqual(0.2, distribution["protocolFeeAmount"]! as! UFix64)
}

// ============================================================================
// TESTS - Strategy Name
// ============================================================================

access(all) fun testDistributionStrategyNameFormat() {
    let poolID = createPoolWithDistribution(rewards: 0.7, prize: 0.2, protocolFee: 0.1)
    
    let strategyName = getDistributionStrategyName(poolID: poolID)
    // Strategy name format: "Fixed: 0.70000000 rewards, 0.20000000 prize"
    Test.assert(strategyName.length > 0, message: "Strategy name should not be empty")
    Test.assert(strategyName.utf8.length > 5, message: "Strategy name should contain meaningful content")
}

// ============================================================================
// TESTS - Invalid Configurations (Failure Cases)
// ============================================================================

access(all) fun testDistributionStrategySumNotOneReverts() {
    // This test verifies that creating a strategy with sum != 1.0 fails
    // We expect the transaction to fail
    let result = createPoolWithDistributionExpectFailure(rewards: 0.5, prize: 0.3, protocolFee: 0.1)
    Test.assertEqual(false, result)
}

