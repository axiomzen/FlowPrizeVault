import Test
import "PrizeSavings"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// SHARE PRICE PRECISION TEST SUITE
// ============================================================================
// 
// This test file verifies precision-related edge cases for share price 
// calculations in the PrizeSavings contract. UFix64 has 8 decimal places
// of precision, and these tests ensure the contract handles edge cases
// properly without accumulating significant rounding errors.
//
// Key areas tested:
// 1. Share price stability after yield
// 2. Round-trip deposit/withdraw precision
// 3. Minimum UFix64 amounts (0.00000001)
// 4. Empty pool handling
// 5. Multiple users fairness
//
// NOTE: Long-running tests (many iterations, extreme values) are in:
//       cadence/long_tests/SharePricePrecision_long_test.cdc
//
// To run all tests including long-running:
//   flow test cadence/tests/ cadence/long_tests/
// ============================================================================

// ============================================================================
// CONSTANTS
// ============================================================================

// UFix64 precision constant
access(all) let UFIX64_PRECISION: UFix64 = 0.00000001

// Test amounts
access(all) let NORMAL_DEPOSIT: UFix64 = 100.0
access(all) let SMALL_DEPOSIT: UFix64 = 0.001
access(all) let TINY_DEPOSIT: UFix64 = 0.00001
access(all) let MINIMUM_DEPOSIT: UFix64 = 0.00000001  // Smallest UFix64

// Vault prefix for this test file's pools
access(all) let PRECISION_VAULT_PREFIX: String = "testYieldVaultPrecision_"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Share Price Initial State
// ============================================================================

access(all) fun testSharePriceStartsAtOne() {
    // Create fresh pool
    let poolID = createTestPoolWithShortInterval()
    
    // Verify initial share price is exactly 1.0 for empty pool
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let sharePrice = precisionInfo["sharePrice"]!
    
    // Empty pool should have share price of exactly 1.0
    Test.assertEqual(1.0, sharePrice)
    
    // Verify totals are zero for empty pool
    Test.assertEqual(0.0, precisionInfo["totalAssets"]!)
    Test.assertEqual(0.0, precisionInfo["totalShares"]!)
}

access(all) fun testSharePriceAfterFirstDeposit() {
    // Create fresh pool
    let poolID = createTestPoolWithShortInterval()
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: NORMAL_DEPOSIT + 1.0)
    depositToPool(user, poolID: poolID, amount: NORMAL_DEPOSIT)
    
    // Share price should be exactly 1.0 (no yield has occurred)
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let sharePrice = precisionInfo["sharePrice"]!
    
    // With deposit of 100 and no yield:
    // sharePrice = 100 / 100 = 1.0 exactly
    Test.assertEqual(1.0, sharePrice)
    
    // Verify assets and shares match deposit exactly
    Test.assertEqual(NORMAL_DEPOSIT, precisionInfo["totalAssets"]!)
    Test.assertEqual(NORMAL_DEPOSIT, precisionInfo["totalShares"]!)
}

// ============================================================================
// TEST: Round-Trip Deposit/Withdraw Precision
// ============================================================================

access(all) fun testRoundTripNormalAmount() {
    // Test: Deposit X, withdraw all, verify received amount equals X exactly
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 50.0
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 1.0)
    
    // Record FLOW balance after setup, before deposit
    let preDepositFlowBalance = getUserFlowBalance(user.address)
    
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Record FLOW balance after deposit
    let postDepositFlowBalance = getUserFlowBalance(user.address)
    
    // Verify user balance equals deposit exactly
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    // Asset value should equal deposit exactly (no yield has occurred)
    Test.assertEqual(depositAmount, assetValue)
    
    // Precision loss should be zero
    let precisionLoss = userDetails["precisionLoss"]!
    Test.assertEqual(0.0, precisionLoss)
    
    // Actually withdraw and verify received amount matches deposit exactly
    withdrawFromPool(user, poolID: poolID, amount: assetValue)
    let finalFlowBalance = getUserFlowBalance(user.address)
    let recovered = finalFlowBalance - postDepositFlowBalance
    
    Test.assertEqual(depositAmount, recovered)
}

access(all) fun testRoundTripSmallAmount() {
    // Test round-trip with small deposit (0.001)
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.0001)
    let depositAmount: UFix64 = 0.001
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 1.0)
    
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Record FLOW balance after deposit
    let postDepositFlowBalance = getUserFlowBalance(user.address)
    
    // Verify precision - should be exact with no virtual shares
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    let precisionLoss = userDetails["precisionLoss"]!
    
    // Asset value should equal deposit exactly
    Test.assertEqual(depositAmount, assetValue)
    
    // Precision loss should be zero
    Test.assertEqual(0.0, precisionLoss)
    
    // Actually withdraw and verify received amount
    withdrawFromPool(user, poolID: poolID, amount: assetValue)
    let finalFlowBalance = getUserFlowBalance(user.address)
    let recovered = finalFlowBalance - postDepositFlowBalance
    
    Test.assertEqual(depositAmount, recovered)
}

// ============================================================================
// TEST: Share Price After Yield
// ============================================================================

access(all) fun testSharePriceAfterYieldDistribution() {
    // Test share price changes correctly after yield
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 100.0
    
    // User deposits
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 1.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Record pre-yield state
    let preYieldInfo = getSharePricePrecisionInfo(poolID)
    let preYieldSharePrice = preYieldInfo["sharePrice"]!
    let preYieldShares = preYieldInfo["totalShares"]!
    
    // Simulate yield (add assets to the pool)
    // Need to find the pool index - it should be the last one created
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let yieldAmount: UFix64 = 10.0
    
    // Use standard prefix for short interval pools
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: "testYieldVaultShort_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Record post-yield state
    let postYieldInfo = getSharePricePrecisionInfo(poolID)
    let postYieldSharePrice = postYieldInfo["sharePrice"]!
    let postYieldShares = postYieldInfo["totalShares"]!
    
    // Shares should not change at all (yield increases assets, not shares)
    Test.assertEqual(preYieldShares, postYieldShares)
    
    // Share price should have increased (more assets per share)
    Test.assert(
        postYieldSharePrice > preYieldSharePrice,
        message: "Share price should increase after yield. Pre: "
            .concat(preYieldSharePrice.toString())
            .concat(", Post: ").concat(postYieldSharePrice.toString())
    )
}

// ============================================================================
// TEST: Extreme Asset/Share Ratios
// ============================================================================

access(all) fun testLargeAssetSmallShares() {
    // Test behavior when totalAssets >> totalShares (high share price)
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 10.0
    
    // User deposits
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: depositAmount + 1.0)
    depositToPool(user, poolID: poolID, amount: depositAmount)
    
    // Add significant yield
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let yieldAmount: UFix64 = 100.0  // 10x the deposit
    
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: "testYieldVaultShort_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check share price
    let info = getSharePricePrecisionInfo(poolID)
    let sharePrice = info["sharePrice"]!
    
    // Share price should be significantly > 1.0
    // With 70% savings distribution: 10 initial + 70 yield = 80 assets for 10 shares
    // sharePrice = 80/10 = 8.0
    Test.assert(
        sharePrice > 1.0,
        message: "Share price should be > 1.0 with high yield. Got: ".concat(sharePrice.toString())
    )
    
    // User's value should have increased proportionally
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    Test.assert(
        assetValue > depositAmount,
        message: "User asset value should have increased from yield. Original: "
            .concat(depositAmount.toString())
            .concat(", Current: ").concat(assetValue.toString())
    )
}

access(all) fun testLargeDeposit() {
    // Test behavior with a very large deposit
    let poolID = createTestPoolWithShortInterval()
    let largeDeposit: UFix64 = 10000000.0  // 10 million
    
    // User deposits
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: largeDeposit + 1.0)
    depositToPool(user, poolID: poolID, amount: largeDeposit)
    
    // Verify precision
    let info = getSharePricePrecisionInfo(poolID)
    let sharePrice = info["sharePrice"]!
    
    // Share price should be exactly 1.0 (large deposit, no yield yet)
    Test.assertEqual(1.0, sharePrice)
    
    // Total assets and shares should match exactly
    Test.assertEqual(largeDeposit, info["totalAssets"]!)
    Test.assertEqual(largeDeposit, info["totalShares"]!)
}

// ============================================================================
// TEST: Tiny Amounts (Edge Cases)
// ============================================================================

access(all) fun testMinimumUFix64Deposit() {
    // Test with smallest possible UFix64 value
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    let tinyAmount: UFix64 = 0.00000001  // Minimum UFix64
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1.0)
    
    depositToPool(user, poolID: poolID, amount: tinyAmount)
    
    let userDetails = getUserShareDetails(user.address, poolID)
    let shares = userDetails["shares"]!
    
    // Shares should equal deposit exactly at share price 1.0
    Test.assertEqual(tinyAmount, shares)
}

access(all) fun testMultipleTinyDeposits() {
    // Test accumulation of many tiny deposits
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    let tinyAmount: UFix64 = 0.00000001
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1.0)
    
    // Make multiple tiny deposits
    var i = 0
    while i < 10 {
        depositToPool(user, poolID: poolID, amount: tinyAmount)
        i = i + 1
    }
    
    // Verify the deposit was processed
    let info = getSharePricePrecisionInfo(poolID)
    let totalAssets = info["totalAssets"]!
    
    // Total should be exactly 10 * tinyAmount
    let expectedTotal = tinyAmount * 10.0
    Test.assertEqual(expectedTotal, totalAssets)
}

// ============================================================================
// TEST: Empty Pool Handling
// ============================================================================

access(all) fun testEmptyPoolReturnsSharePriceOne() {
    // Test that empty pool returns share price of 1.0 (not division by zero)
    let poolID = createTestPoolWithShortInterval()
    
    // Query share price on empty pool (no deposits)
    let info = getSharePricePrecisionInfo(poolID)
    
    // Should return valid share price of 1.0, not panic
    let sharePrice = info["sharePrice"]!
    Test.assertEqual(1.0, sharePrice)
    
    // Total values should be zero
    Test.assertEqual(0.0, info["totalAssets"]!)
    Test.assertEqual(0.0, info["totalShares"]!)
}

access(all) fun testLargeDepositHasNoDilution() {
    // Test that large deposits are not diluted in any way
    let poolID = createTestPoolWithShortInterval()
    let largeDeposit: UFix64 = 1000000.0  // 1 million
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: largeDeposit + 1.0)
    depositToPool(user, poolID: poolID, amount: largeDeposit)
    
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    // Asset value should exactly equal deposit (no dilution)
    Test.assertEqual(largeDeposit, assetValue)
}

// ============================================================================
// TEST: Multiple Users Fairness
// ============================================================================

access(all) fun testEqualDepositsGetEqualShares() {
    // Test that equal deposits at the same share price get equal shares
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 50.0
    
    // Two users deposit the same amount
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: depositAmount + 1.0)
    setupUserWithFundsAndCollection(user2, amount: depositAmount + 1.0)
    
    depositToPool(user1, poolID: poolID, amount: depositAmount)
    depositToPool(user2, poolID: poolID, amount: depositAmount)
    
    // Both should have the exact same number of shares
    let user1Details = getUserShareDetails(user1.address, poolID)
    let user2Details = getUserShareDetails(user2.address, poolID)
    
    Test.assertEqual(user1Details["shares"]!, user2Details["shares"]!)
    Test.assertEqual(user1Details["assetValue"]!, user2Details["assetValue"]!)
}

access(all) fun testProportionalSharesWithDifferentAmounts() {
    // Test that deposit amounts result in proportional shares
    let poolID = createTestPoolWithShortInterval()
    let smallDeposit: UFix64 = 10.0
    let largeDeposit: UFix64 = 100.0
    
    let smallUser = Test.createAccount()
    let largeUser = Test.createAccount()
    
    setupUserWithFundsAndCollection(smallUser, amount: smallDeposit + 1.0)
    setupUserWithFundsAndCollection(largeUser, amount: largeDeposit + 1.0)
    
    depositToPool(smallUser, poolID: poolID, amount: smallDeposit)
    depositToPool(largeUser, poolID: poolID, amount: largeDeposit)
    
    let smallDetails = getUserShareDetails(smallUser.address, poolID)
    let largeDetails = getUserShareDetails(largeUser.address, poolID)
    
    // Large user should have exactly 10x the shares of small user
    let ratio = largeDetails["shares"]! / smallDetails["shares"]!
    Test.assertEqual(10.0, ratio)
}

// ============================================================================
// TEST: Consistency Checks
// ============================================================================

access(all) fun testAssetsEqualsSharesTimesPrice() {
    // Invariant: totalAssets = totalShares * sharePrice exactly
    let poolID = createTestPoolWithShortInterval()
    
    // Multiple deposits
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: 101.0)
        depositToPool(user, poolID: poolID, amount: 20.0 + UFix64(i) * 10.0)
        i = i + 1
    }
    
    let info = getSharePricePrecisionInfo(poolID)
    let sharePrice = info["sharePrice"]!
    let totalAssets = info["totalAssets"]!
    let totalShares = info["totalShares"]!
    
    // assets / shares should equal sharePrice exactly
    let calculatedPrice = totalAssets / totalShares
    Test.assertEqual(calculatedPrice, sharePrice)
}

access(all) fun testTotalDepositsMatchSumOfUserDeposits() {
    // Test that pool's totalDeposited matches sum of individual user deposits
    let poolID = createTestPoolWithShortInterval()
    var expectedTotal: UFix64 = 0.0
    
    // Multiple deposits of varying amounts
    let amounts: [UFix64] = [10.0, 25.5, 100.0, 7.77, 50.0]
    
    var i = 0
    while i < amounts.length {
        let user = Test.createAccount()
        let amount = amounts[i]
        setupUserWithFundsAndCollection(user, amount: amount + 1.0)
        depositToPool(user, poolID: poolID, amount: amount)
        expectedTotal = expectedTotal + amount
        i = i + 1
    }
    
    let info = getSharePricePrecisionInfo(poolID)
    let totalDeposited = info["totalDeposited"]!
    
    Test.assertEqual(expectedTotal, totalDeposited)
}

// ============================================================================
// TEST: Fairness After Yield Distribution
// ============================================================================
// 
// These tests verify that yield distribution maintains fairness invariants.
// In Cadence, inflation attacks (common in EVM vaults) are impossible because:
// 1. Resources cannot be sent to arbitrary storage without capability access
// 2. The pool tracks totalAssets independently, not via balance checks
// 3. Any external yield source balance changes are treated as yield for ALL depositors
//
// ============================================================================

access(all) fun testExternalYieldDistributedFairly() {
    // Proves: Yield benefits all depositors proportionally, not just one
    let poolID = createTestPoolWithShortInterval()
    
    // First user deposits 100.0
    let firstUser = Test.createAccount()
    setupUserWithFundsAndCollection(firstUser, amount: 101.0)
    depositToPool(firstUser, poolID: poolID, amount: 100.0)
    
    // Second user deposits 100.0
    let secondUser = Test.createAccount()
    setupUserWithFundsAndCollection(secondUser, amount: 101.0)
    depositToPool(secondUser, poolID: poolID, amount: 100.0)
    
    // Get initial balances
    let initialFirst = getUserShareDetails(firstUser.address, poolID)["assetValue"]!
    let initialSecond = getUserShareDetails(secondUser.address, poolID)["assetValue"]!
    
    // Both should have exactly equal initial balances
    Test.assertEqual(initialFirst, initialSecond)
    
    // Simulate yield arriving in the yield source (10.0 FLOW)
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: "testYieldVaultShort_")
    
    // Process rewards to sync with yield source
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final balances
    let finalFirst = getUserShareDetails(firstUser.address, poolID)["assetValue"]!
    let finalSecond = getUserShareDetails(secondUser.address, poolID)["assetValue"]!
    
    // Both users should receive equal share of yield since they have equal shares
    let firstGain = finalFirst - initialFirst
    let secondGain = finalSecond - initialSecond
    
    // Key assertion: Both users gain equally
    Test.assertEqual(firstGain, secondGain)
    
    // Both should have gained something (70% of yield goes to savings)
    Test.assert(firstGain > 0.0, message: "First user should have gained yield")
    Test.assert(secondGain > 0.0, message: "Second user should have gained yield")
}

access(all) fun testYieldDistributionIsExact() {
    // Proves: With 100% savings distribution, all yield goes to depositors
    let poolID = createPoolWithDistribution(savings: 1.0, lottery: 0.0, treasury: 0.0)
    
    // User deposits 100.0
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 101.0)
    depositToPool(user, poolID: poolID, amount: 100.0)
    
    let initialValue = getUserShareDetails(user.address, poolID)["assetValue"]!
    Test.assertEqual(100.0, initialValue)
    
    // Add yield to pool (simulate 10.0 FLOW appreciation)
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    
    // Process rewards
    triggerSyncWithYieldSource(poolID: poolID)
    
    // With 100% savings distribution, user should gain exactly 10.0
    let finalValue = getUserShareDetails(user.address, poolID)["assetValue"]!
    let gain = finalValue - initialValue
    
    // Assert exact gain (no dust lost to virtual shares)
    Test.assertEqual(10.0, gain)
    Test.assertEqual(110.0, finalValue)
}

access(all) fun testProportionalSharesAfterYield() {
    // Proves: Users maintain proportional ownership after yield
    let poolID = createTestPoolWithShortInterval()
    
    // User 1 deposits 100
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 101.0)
    depositToPool(user1, poolID: poolID, amount: 100.0)
    
    // User 2 deposits 200 (2x user 1)
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user2, amount: 201.0)
    depositToPool(user2, poolID: poolID, amount: 200.0)
    
    // Add yield
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 30.0, vaultPrefix: "testYieldVaultShort_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Get final values
    let user1Value = getUserShareDetails(user1.address, poolID)["assetValue"]!
    let user2Value = getUserShareDetails(user2.address, poolID)["assetValue"]!
    
    // User 2 should have exactly 2x the value of User 1
    let ratio = user2Value / user1Value
    Test.assertEqual(2.0, ratio)
}
