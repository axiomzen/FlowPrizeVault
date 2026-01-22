import Test
import "test_helpers.cdc"

// ============================================================================
// DISTRIBUTION THRESHOLD PRECISION TEST SUITE
// ============================================================================
// 
// This test file verifies the MINIMUM_DISTRIBUTION_THRESHOLD behavior in the
// PrizeLinkedAccounts contract. The threshold (0.000001 = 100x minimum UFix64)
// prevents precision loss when distributing tiny yield amounts across
// percentage buckets.
//
// Key behaviors tested:
// 1. Yield below threshold is skipped (stays in yield source)
// 2. Yield above threshold is distributed normally
// 3. Accumulated small yields eventually get distributed
// 4. Sum conservation when distributing above threshold
//
// ============================================================================

// ============================================================================
// CONSTANTS
// ============================================================================

// The threshold value from the contract (100x minimum UFix64)
access(all) let DISTRIBUTION_THRESHOLD: UFix64 = 0.000001

// Test amounts relative to threshold
access(all) let BELOW_THRESHOLD: UFix64 = 0.0000004      // 40% of threshold
access(all) let AT_THRESHOLD: UFix64 = 0.000001          // Exactly at threshold
access(all) let ABOVE_THRESHOLD: UFix64 = 0.000002       // 2x threshold
access(all) let WELL_ABOVE_THRESHOLD: UFix64 = 0.00001   // 10x threshold

// UFix64 precision
access(all) let UFIX64_PRECISION: UFix64 = 0.00000001
access(all) let ACCEPTABLE_PRECISION_LOSS: UFix64 = 0.00000002

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Create a pool with a user deposit to enable yield distribution
access(all) fun setupPoolWithDeposit(
    rewards: UFix64, 
    prize: UFix64, 
    protocolFee: UFix64, 
    depositAmount: UFix64
): UInt64 {
    let poolID = createPoolWithDistribution(rewards: rewards, prize: prize, protocolFee: protocolFee)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 10.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    return poolID
}

// ============================================================================
// TEST: Yield Below Threshold Is Skipped
// ============================================================================

access(all) fun testYieldBelowThresholdIsNotDistributed() {
    // Setup: Create pool with 70/20/10 distribution and initial deposit
    let poolID = setupPoolWithDeposit(
        rewards: 0.7, 
        prize: 0.2, 
        protocolFee: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    let initialPendingProtocol = initialInfo["allocatedProtocolFee"]!
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    
    // Simulate very small yield (below threshold)
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    
    // Nothing should have been distributed - all values should be unchanged
    Test.assert(
        initialPendingPrize == finalPendingPrize,
        message: "allocatedPrizeYield should be unchanged when yield is below threshold"
    )
    Test.assert(
        initialPendingProtocol == finalPendingProtocolFee,
        message: "allocatedProtocolFee should be unchanged when yield is below threshold"
    )
    Test.assert(
        initialTotalStaked == finalTotalStaked,
        message: "totalAssets should be unchanged when yield is below threshold"
    )
}

// ============================================================================
// TEST: Yield At/Above Threshold Is Distributed
// ============================================================================

access(all) fun testYieldAtThresholdIsDistributed() {
    // Setup: Create pool with 70/20/10 distribution
    let poolID = setupPoolWithDeposit(
        rewards: 0.7, 
        prize: 0.2, 
        protocolFee: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    
    // Simulate yield exactly at threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // Prize should have received 20% of the yield
    // 0.000001 * 0.2 = 0.0000002
    let expectedPrizeIncrease = AT_THRESHOLD * 0.2
    let actualPrizeIncrease = finalPendingPrize - initialPendingPrize
    
    Test.assert(
        isWithinTolerance(actualPrizeIncrease, expectedPrizeIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Prize should receive ~20% of yield at threshold. Expected: "
            .concat(expectedPrizeIncrease.toString())
            .concat(", Got: ").concat(actualPrizeIncrease.toString())
    )
}

access(all) fun testYieldAboveThresholdIsDistributed() {
    // Setup: Create pool with 50/30/20 distribution for easier math
    let poolID = setupPoolWithDeposit(
        rewards: 0.5, 
        prize: 0.3, 
        protocolFee: 0.2, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    let initialPendingProtocol = initialInfo["allocatedProtocolFee"]!
    
    // Simulate yield well above threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: WELL_ABOVE_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    
    // Prize should have received 30% of the yield
    // 0.00001 * 0.3 = 0.000003
    let expectedPrizeIncrease = WELL_ABOVE_THRESHOLD * 0.3
    let actualPrizeIncrease = finalPendingPrize - initialPendingPrize
    
    Test.assert(
        isWithinTolerance(actualPrizeIncrease, expectedPrizeIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Prize should receive ~30% of yield. Expected: "
            .concat(expectedPrizeIncrease.toString())
            .concat(", Got: ").concat(actualPrizeIncrease.toString())
    )
    
    // Protocol should have received 20% + any dust from rewards
    let minExpectedProtocolIncrease = WELL_ABOVE_THRESHOLD * 0.2
    let actualProtocolIncrease = finalPendingProtocolFee - initialPendingProtocol
    
    Test.assert(
        actualProtocolIncrease >= minExpectedProtocolIncrease,
        message: "Protocol should receive at least 20% of yield. Expected min: "
            .concat(minExpectedProtocolIncrease.toString())
            .concat(", Got: ").concat(actualProtocolIncrease.toString())
    )
}

// ============================================================================
// TEST: Accumulated Small Yields Get Distributed
// ============================================================================

access(all) fun testAccumulatedYieldEventuallyDistributed() {
    // Setup: Create pool with 70/20/10 distribution
    let poolID = setupPoolWithDeposit(
        rewards: 0.7, 
        prize: 0.2, 
        protocolFee: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    
    log("=== Initial State ===")
    log("Initial allocatedPrizeYield: ".concat(initialPendingPrize.toString()))
    log("BELOW_THRESHOLD amount: ".concat(BELOW_THRESHOLD.toString()))
    log("DISTRIBUTION_THRESHOLD: ".concat(DISTRIBUTION_THRESHOLD.toString()))
    
    let poolIndex = Int(poolID)
    
    // Simulate 3 small yields that individually are below threshold
    // but combined exceed it: 0.0000005 * 3 = 0.0000015 > 0.000001
    log("=== After 1st small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    let info1 = getPoolRewardsInfo(poolID)
    log("pendingPrizeYield after 1st: ".concat(info1["allocatedPrizeYield"]!.toString()))
    
    log("=== After 2nd small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // After 2 syncs, still below threshold (0.000001), nothing distributed
    let midInfo = getPoolRewardsInfo(poolID)
    let midPendingPrize = midInfo["allocatedPrizeYield"]!
    log("pendingPrizeYield after 2nd: ".concat(midPendingPrize.toString()))
    log("Expected (initial): ".concat(initialPendingPrize.toString()))
    log("Are they equal? ".concat(initialPendingPrize == midPendingPrize ? "Yes" : "No"))
    
    Test.assert(
        initialPendingPrize == midPendingPrize,
        message: "After 2 small yields, still below threshold - nothing distributed. Initial: "
            .concat(initialPendingPrize.toString())
            .concat(", After 2nd: ").concat(midPendingPrize.toString())
    )
    
    // Third small yield pushes total above threshold
    log("=== After 3rd small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Now the accumulated yield (0.0000015) should be distributed
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    log("pendingPrizeYield after 3rd: ".concat(finalPendingPrize.toString()))
    
    Test.assert(
        finalPendingPrize > initialPendingPrize,
        message: "After accumulated yield exceeds threshold, prize should receive funds"
    )
}

// ============================================================================
// TEST: Sum Conservation Above Threshold
// ============================================================================

access(all) fun testSumConservationAboveThreshold() {
    // Setup: Create pool with 40/40/20 distribution
    let poolID = setupPoolWithDeposit(
        rewards: 0.4, 
        prize: 0.4, 
        protocolFee: 0.2, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    let initialPendingProtocol = initialInfo["allocatedProtocolFee"]!
    let initialAllocated = initialTotalStaked + initialPendingPrize + initialPendingProtocol
    
    // Add yield well above threshold
    let yieldAmount: UFix64 = 1.0  // 1 FLOW - well above threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    let finalAllocated = finalTotalStaked + finalPendingPrize + finalPendingProtocolFee
    
    // The increase in allocated funds should equal the yield amount
    let allocatedIncrease = finalAllocated - initialAllocated
    
    Test.assert(
        isWithinTolerance(allocatedIncrease, yieldAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Sum of allocated funds should increase by yield amount. Expected: "
            .concat(yieldAmount.toString())
            .concat(", Got: ").concat(allocatedIncrease.toString())
    )
}

// ============================================================================
// TEST: Different Percentage Splits
// ============================================================================

access(all) fun testThresholdWithThirdsSplit() {
    // Setup: Create pool with 33/33/34 distribution (approximate thirds)
    let poolID = setupPoolWithDeposit(
        rewards: 0.33, 
        prize: 0.33, 
        protocolFee: 0.34, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    
    // Add yield at threshold - with thirds, each bucket gets 0.00000033
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // Prize should have received 33% of yield
    // 0.000001 * 0.33 = 0.00000033
    let expectedPrizeIncrease = AT_THRESHOLD * 0.33
    let actualPrizeIncrease = finalPendingPrize - initialPendingPrize
    
    Test.assert(
        isWithinTolerance(actualPrizeIncrease, expectedPrizeIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Prize should receive ~33% of yield with thirds split. Expected: "
            .concat(expectedPrizeIncrease.toString())
            .concat(", Got: ").concat(actualPrizeIncrease.toString())
    )
}

access(all) fun testThresholdWithSmallProtocolPercentage() {
    // Setup: Create pool with 80/15/5 distribution (small protocol %)
    let poolID = setupPoolWithDeposit(
        rewards: 0.8, 
        prize: 0.15, 
        protocolFee: 0.05, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingProtocol = initialInfo["allocatedProtocolFee"]!
    
    // Add yield at threshold - protocol fee gets 5% = 0.00000005
    // This is above minimum UFix64, so it should work
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingProtocolFee = finalInfo["allocatedProtocolFee"]!
    
    // Protocol should have received 5% of yield + dust from rewards
    // 0.000001 * 0.05 = 0.00000005 (minimum increase, may have dust added)
    let minExpectedProtocolIncrease = AT_THRESHOLD * 0.05
    let actualProtocolIncrease = finalPendingProtocolFee - initialPendingProtocol
    
    Test.assert(
        actualProtocolIncrease >= minExpectedProtocolIncrease,
        message: "Protocol should receive at least 5% of yield. Expected min: "
            .concat(minExpectedProtocolIncrease.toString())
            .concat(", Got: ").concat(actualProtocolIncrease.toString())
    )
}

// ============================================================================
// TEST: Zero Yield Handling (Edge Case)
// ============================================================================

access(all) fun testZeroYieldNotDistributed() {
    // Setup: Create pool with standard distribution
    let poolID = setupPoolWithDeposit(
        rewards: 0.7, 
        prize: 0.2, 
        protocolFee: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialPendingPrize = initialInfo["allocatedPrizeYield"]!
    
    // Trigger sync without adding any yield
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalPendingPrize = finalInfo["allocatedPrizeYield"]!
    
    // Nothing should change
    Test.assert(
        initialPendingPrize == finalPendingPrize,
        message: "Zero yield should not affect allocated prize yield"
    )
}

// ============================================================================
// TEST: Deficit Below Threshold Is Skipped
// ============================================================================

access(all) fun testDeficitBelowThresholdIsNotApplied() {
    // Setup: Create pool with 100% rewards for simpler verification
    let poolID = setupPoolWithDeposit(
        rewards: 1.0, 
        prize: 0.0, 
        protocolFee: 0.0, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Simulate very small deficit (below threshold)
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Nothing should have changed - deficit below threshold is skipped
    Test.assert(
        initialTotalStaked == finalTotalStaked,
        message: "totalAssets should be unchanged when deficit is below threshold"
    )
    Test.assert(
        initialSharePrice == finalSharePrice,
        message: "sharePrice should be unchanged when deficit is below threshold"
    )
}

// ============================================================================
// TEST: Deficit At Threshold Is Applied
// ============================================================================

access(all) fun testDeficitAtThresholdIsApplied() {
    // Setup: Create pool with 100% rewards for simpler verification
    let poolID = setupPoolWithDeposit(
        rewards: 1.0, 
        prize: 0.0, 
        protocolFee: 0.0, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolRewardsInfo(poolID)
    let initialTotalStaked = initialInfo["allocatedRewards"]!
    
    // Simulate deficit exactly at threshold
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolRewardsInfo(poolID)
    let finalTotalStaked = finalInfo["allocatedRewards"]!
    
    // Deficit at threshold should be applied
    Test.assert(
        finalTotalStaked < initialTotalStaked,
        message: "totalAssets should decrease when deficit is at threshold. Initial: "
            .concat(initialTotalStaked.toString())
            .concat(", Final: ").concat(finalTotalStaked.toString())
    )
}

