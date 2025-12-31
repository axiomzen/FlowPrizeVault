import Test
import "test_helpers.cdc"

// ============================================================================
// DISTRIBUTION THRESHOLD PRECISION TEST SUITE
// ============================================================================
// 
// This test file verifies the MINIMUM_DISTRIBUTION_THRESHOLD behavior in the
// PrizeSavings contract. The threshold (0.000001 = 100x minimum UFix64)
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
    savings: UFix64, 
    lottery: UFix64, 
    treasury: UFix64, 
    depositAmount: UFix64
): UInt64 {
    let poolID = createPoolWithDistribution(savings: savings, lottery: lottery, treasury: treasury)
    
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
        savings: 0.7, 
        lottery: 0.2, 
        treasury: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    let initialPendingTreasury = initialInfo["pendingTreasuryYield"]!
    let initialTotalStaked = initialInfo["totalStaked"]!
    
    // Simulate very small yield (below threshold)
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    let finalPendingTreasury = finalInfo["pendingTreasuryYield"]!
    let finalTotalStaked = finalInfo["totalStaked"]!
    
    // Nothing should have been distributed - all values should be unchanged
    Test.assert(
        initialPendingLottery == finalPendingLottery,
        message: "pendingLotteryYield should be unchanged when yield is below threshold"
    )
    Test.assert(
        initialPendingTreasury == finalPendingTreasury,
        message: "pendingTreasuryYield should be unchanged when yield is below threshold"
    )
    Test.assert(
        initialTotalStaked == finalTotalStaked,
        message: "totalStaked should be unchanged when yield is below threshold"
    )
}

// ============================================================================
// TEST: Yield At/Above Threshold Is Distributed
// ============================================================================

access(all) fun testYieldAtThresholdIsDistributed() {
    // Setup: Create pool with 70/20/10 distribution
    let poolID = setupPoolWithDeposit(
        savings: 0.7, 
        lottery: 0.2, 
        treasury: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    
    // Simulate yield exactly at threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // Lottery should have received 20% of the yield
    // 0.000001 * 0.2 = 0.0000002
    let expectedLotteryIncrease = AT_THRESHOLD * 0.2
    let actualLotteryIncrease = finalPendingLottery - initialPendingLottery
    
    Test.assert(
        isWithinTolerance(actualLotteryIncrease, expectedLotteryIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Lottery should receive ~20% of yield at threshold. Expected: "
            .concat(expectedLotteryIncrease.toString())
            .concat(", Got: ").concat(actualLotteryIncrease.toString())
    )
}

access(all) fun testYieldAboveThresholdIsDistributed() {
    // Setup: Create pool with 50/30/20 distribution for easier math
    let poolID = setupPoolWithDeposit(
        savings: 0.5, 
        lottery: 0.3, 
        treasury: 0.2, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    let initialPendingTreasury = initialInfo["pendingTreasuryYield"]!
    
    // Simulate yield well above threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: WELL_ABOVE_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    let finalPendingTreasury = finalInfo["pendingTreasuryYield"]!
    
    // Lottery should have received 30% of the yield
    // 0.00001 * 0.3 = 0.000003
    let expectedLotteryIncrease = WELL_ABOVE_THRESHOLD * 0.3
    let actualLotteryIncrease = finalPendingLottery - initialPendingLottery
    
    Test.assert(
        isWithinTolerance(actualLotteryIncrease, expectedLotteryIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Lottery should receive ~30% of yield. Expected: "
            .concat(expectedLotteryIncrease.toString())
            .concat(", Got: ").concat(actualLotteryIncrease.toString())
    )
    
    // Treasury should have received 20% + any dust from savings
    let minExpectedTreasuryIncrease = WELL_ABOVE_THRESHOLD * 0.2
    let actualTreasuryIncrease = finalPendingTreasury - initialPendingTreasury
    
    Test.assert(
        actualTreasuryIncrease >= minExpectedTreasuryIncrease,
        message: "Treasury should receive at least 20% of yield. Expected min: "
            .concat(minExpectedTreasuryIncrease.toString())
            .concat(", Got: ").concat(actualTreasuryIncrease.toString())
    )
}

// ============================================================================
// TEST: Accumulated Small Yields Get Distributed
// ============================================================================

access(all) fun testAccumulatedYieldEventuallyDistributed() {
    // Setup: Create pool with 70/20/10 distribution
    let poolID = setupPoolWithDeposit(
        savings: 0.7, 
        lottery: 0.2, 
        treasury: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    
    log("=== Initial State ===")
    log("Initial pendingLotteryYield: ".concat(initialPendingLottery.toString()))
    log("BELOW_THRESHOLD amount: ".concat(BELOW_THRESHOLD.toString()))
    log("DISTRIBUTION_THRESHOLD: ".concat(DISTRIBUTION_THRESHOLD.toString()))
    
    let poolIndex = Int(poolID)
    
    // Simulate 3 small yields that individually are below threshold
    // but combined exceed it: 0.0000005 * 3 = 0.0000015 > 0.000001
    log("=== After 1st small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    let info1 = getPoolSavingsInfo(poolID)
    log("pendingLotteryYield after 1st: ".concat(info1["pendingLotteryYield"]!.toString()))
    
    log("=== After 2nd small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // After 2 syncs, still below threshold (0.000001), nothing distributed
    let midInfo = getPoolSavingsInfo(poolID)
    let midPendingLottery = midInfo["pendingLotteryYield"]!
    log("pendingLotteryYield after 2nd: ".concat(midPendingLottery.toString()))
    log("Expected (initial): ".concat(initialPendingLottery.toString()))
    log("Are they equal? ".concat(initialPendingLottery == midPendingLottery ? "Yes" : "No"))
    
    Test.assert(
        initialPendingLottery == midPendingLottery,
        message: "After 2 small yields, still below threshold - nothing distributed. Initial: "
            .concat(initialPendingLottery.toString())
            .concat(", After 2nd: ").concat(midPendingLottery.toString())
    )
    
    // Third small yield pushes total above threshold
    log("=== After 3rd small yield ===")
    simulateYieldAppreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Now the accumulated yield (0.0000015) should be distributed
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    log("pendingLotteryYield after 3rd: ".concat(finalPendingLottery.toString()))
    
    Test.assert(
        finalPendingLottery > initialPendingLottery,
        message: "After accumulated yield exceeds threshold, lottery should receive funds"
    )
}

// ============================================================================
// TEST: Sum Conservation Above Threshold
// ============================================================================

access(all) fun testSumConservationAboveThreshold() {
    // Setup: Create pool with 40/40/20 distribution
    let poolID = setupPoolWithDeposit(
        savings: 0.4, 
        lottery: 0.4, 
        treasury: 0.2, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    let initialPendingTreasury = initialInfo["pendingTreasuryYield"]!
    let initialAllocated = initialTotalStaked + initialPendingLottery + initialPendingTreasury
    
    // Add yield well above threshold
    let yieldAmount: UFix64 = 1.0  // 1 FLOW - well above threshold
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    let finalPendingTreasury = finalInfo["pendingTreasuryYield"]!
    let finalAllocated = finalTotalStaked + finalPendingLottery + finalPendingTreasury
    
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
        savings: 0.33, 
        lottery: 0.33, 
        treasury: 0.34, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    
    // Add yield at threshold - with thirds, each bucket gets 0.00000033
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // Lottery should have received 33% of yield
    // 0.000001 * 0.33 = 0.00000033
    let expectedLotteryIncrease = AT_THRESHOLD * 0.33
    let actualLotteryIncrease = finalPendingLottery - initialPendingLottery
    
    Test.assert(
        isWithinTolerance(actualLotteryIncrease, expectedLotteryIncrease, ACCEPTABLE_PRECISION_LOSS),
        message: "Lottery should receive ~33% of yield with thirds split. Expected: "
            .concat(expectedLotteryIncrease.toString())
            .concat(", Got: ").concat(actualLotteryIncrease.toString())
    )
}

access(all) fun testThresholdWithSmallTreasuryPercentage() {
    // Setup: Create pool with 80/15/5 distribution (small treasury %)
    let poolID = setupPoolWithDeposit(
        savings: 0.8, 
        lottery: 0.15, 
        treasury: 0.05, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingTreasury = initialInfo["pendingTreasuryYield"]!
    
    // Add yield at threshold - treasury gets 5% = 0.00000005
    // This is above minimum UFix64, so it should work
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingTreasury = finalInfo["pendingTreasuryYield"]!
    
    // Treasury should have received 5% of yield + dust from savings
    // 0.000001 * 0.05 = 0.00000005 (minimum increase, may have dust added)
    let minExpectedTreasuryIncrease = AT_THRESHOLD * 0.05
    let actualTreasuryIncrease = finalPendingTreasury - initialPendingTreasury
    
    Test.assert(
        actualTreasuryIncrease >= minExpectedTreasuryIncrease,
        message: "Treasury should receive at least 5% of yield. Expected min: "
            .concat(minExpectedTreasuryIncrease.toString())
            .concat(", Got: ").concat(actualTreasuryIncrease.toString())
    )
}

// ============================================================================
// TEST: Zero Yield Handling (Edge Case)
// ============================================================================

access(all) fun testZeroYieldNotDistributed() {
    // Setup: Create pool with standard distribution
    let poolID = setupPoolWithDeposit(
        savings: 0.7, 
        lottery: 0.2, 
        treasury: 0.1, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialPendingLottery = initialInfo["pendingLotteryYield"]!
    
    // Trigger sync without adding any yield
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalPendingLottery = finalInfo["pendingLotteryYield"]!
    
    // Nothing should change
    Test.assert(
        initialPendingLottery == finalPendingLottery,
        message: "Zero yield should not affect pending lottery"
    )
}

// ============================================================================
// TEST: Deficit Below Threshold Is Skipped
// ============================================================================

access(all) fun testDeficitBelowThresholdIsNotApplied() {
    // Setup: Create pool with 100% savings for simpler verification
    let poolID = setupPoolWithDeposit(
        savings: 1.0, 
        lottery: 0.0, 
        treasury: 0.0, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Simulate very small deficit (below threshold)
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: BELOW_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Nothing should have changed - deficit below threshold is skipped
    Test.assert(
        initialTotalStaked == finalTotalStaked,
        message: "totalStaked should be unchanged when deficit is below threshold"
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
    // Setup: Create pool with 100% savings for simpler verification
    let poolID = setupPoolWithDeposit(
        savings: 1.0, 
        lottery: 0.0, 
        treasury: 0.0, 
        depositAmount: 100.0
    )
    
    // Get initial state
    let initialInfo = getPoolSavingsInfo(poolID)
    let initialTotalStaked = initialInfo["totalStaked"]!
    
    // Simulate deficit exactly at threshold
    let poolIndex = Int(poolID)
    simulateYieldDepreciation(poolIndex: poolIndex, amount: AT_THRESHOLD, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final state
    let finalInfo = getPoolSavingsInfo(poolID)
    let finalTotalStaked = finalInfo["totalStaked"]!
    
    // Deficit at threshold should be applied
    Test.assert(
        finalTotalStaked < initialTotalStaked,
        message: "totalStaked should decrease when deficit is at threshold. Initial: "
            .concat(initialTotalStaked.toString())
            .concat(", Final: ").concat(finalTotalStaked.toString())
    )
}

