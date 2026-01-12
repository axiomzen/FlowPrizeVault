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
// 4. Virtual offset protection
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

// UFix64 precision constants
access(all) let UFIX64_PRECISION: UFix64 = 0.00000001
access(all) let ACCEPTABLE_PRECISION_LOSS: UFix64 = 0.00000002  // 2 units of precision

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
    
    // Verify initial share price is 1.0 (or very close due to virtual offsets)
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let sharePrice = precisionInfo["sharePrice"]!
    
    // With virtual offsets of 0.0001 each:
    // sharePrice = (0 + 0.0001) / (0 + 0.0001) = 1.0
    Test.assertEqual(1.0, sharePrice)
    
    // Verify virtual offsets
    Test.assertEqual(0.0001, precisionInfo["virtualAssets"]!)
    Test.assertEqual(0.0001, precisionInfo["virtualShares"]!)
}

access(all) fun testSharePriceAfterFirstDeposit() {
    // Create fresh pool
    let poolID = createTestPoolWithShortInterval()
    
    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: NORMAL_DEPOSIT + 1.0)
    depositToPool(user, poolID: poolID, amount: NORMAL_DEPOSIT)
    
    // Share price should still be very close to 1.0
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let sharePrice = precisionInfo["sharePrice"]!
    
    // With deposit of 100:
    // sharePrice = (100 + 0.0001) / (100 + 0.0001) = 1.0
    Test.assert(
        isWithinTolerance(sharePrice, 1.0, UFIX64_PRECISION),
        message: "Share price should be ~1.0 after first deposit, got: ".concat(sharePrice.toString())
    )
    
    // Verify assets and shares match deposit
    Test.assertEqual(NORMAL_DEPOSIT, precisionInfo["totalAssets"]!)
    Test.assertEqual(NORMAL_DEPOSIT, precisionInfo["totalShares"]!)
}

// ============================================================================
// TEST: Round-Trip Deposit/Withdraw Precision
// ============================================================================

access(all) fun testRoundTripNormalAmount() {
    // Test: Deposit X, withdraw all, verify received amount equals X
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
    
    // Verify user balance equals deposit
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    // Asset value should equal deposit (no yield has occurred)
    Test.assert(
        isWithinTolerance(assetValue, depositAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Asset value should match deposit. Expected: "
            .concat(depositAmount.toString())
            .concat(", got: ").concat(assetValue.toString())
    )
    
    // Actually withdraw and verify received amount matches deposit
    withdrawFromPool(user, poolID: poolID, amount: assetValue)
    let finalFlowBalance = getUserFlowBalance(user.address)
    let recovered = finalFlowBalance - postDepositFlowBalance
    
    Test.assert(
        isWithinTolerance(recovered, depositAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Round-trip recovery failed. Deposited: "
            .concat(depositAmount.toString())
            .concat(", Recovered: ").concat(recovered.toString())
    )
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
    
    // Verify asset value
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    // Actually withdraw and verify received amount
    withdrawFromPool(user, poolID: poolID, amount: assetValue)
    let finalFlowBalance = getUserFlowBalance(user.address)
    let recovered = finalFlowBalance - postDepositFlowBalance
    
    Test.assert(
        isWithinTolerance(recovered, depositAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Small amount round-trip failed. Deposited: "
            .concat(depositAmount.toString())
            .concat(", Recovered: ").concat(recovered.toString())
    )
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
    
    // Shares should not change (yield increases assets, not shares)
    // Note: Actually, only ~70% goes to savings due to distribution strategy
    // The shares should be essentially unchanged
    Test.assert(
        isWithinTolerance(postYieldShares, preYieldShares, ACCEPTABLE_PRECISION_LOSS),
        message: "Shares changed after yield distribution. Pre: "
            .concat(preYieldShares.toString())
            .concat(", Post: ").concat(postYieldShares.toString())
    )
    
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
    // This happens naturally as yield accumulates
    let poolID = createTestPoolWithShortInterval()
    let initialDeposit: UFix64 = 10.0
    
    // User deposits a small amount
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: initialDeposit + 1.0)
    depositToPool(user, poolID: poolID, amount: initialDeposit)
    
    // Simulate significant yield (larger than deposit)
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let largeYield: UFix64 = 100.0
    
    simulateYieldAppreciation(poolIndex: poolIndex, amount: largeYield, vaultPrefix: "testYieldVaultShort_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check share price
    let info = getSharePricePrecisionInfo(poolID)
    let sharePrice = info["sharePrice"]!
    
    // Share price should be significantly > 1.0
    // With 70% savings distribution: 10 initial + 70 yield = 80 assets for 10 shares
    // sharePrice ≈ 80/10 = 8.0 (approximate, accounting for dust)
    Test.assert(
        sharePrice > 1.0,
        message: "Share price should be > 1.0 with yield. Got: ".concat(sharePrice.toString())
    )
    
    // User should have gained value
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    Test.assert(
        assetValue > initialDeposit,
        message: "User asset value should exceed deposit. Value: "
            .concat(assetValue.toString())
            .concat(", Deposit: ").concat(initialDeposit.toString())
    )
}

access(all) fun testNewDepositAfterSharePriceIncrease() {
    // Test that new deposits after share price increase get fewer shares
    let poolID = createTestPoolWithShortInterval()
    let initialDeposit: UFix64 = 100.0
    
    // First user deposits
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: initialDeposit + 1.0)
    depositToPool(user1, poolID: poolID, amount: initialDeposit)
    
    // Record user1's shares
    let user1Details = getUserShareDetails(user1.address, poolID)
    let user1Shares = user1Details["shares"]!
    
    // Simulate yield
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let yieldAmount: UFix64 = 50.0
    
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: "testYieldVaultShort_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Second user deposits same amount after yield
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user2, amount: initialDeposit + 1.0)
    depositToPool(user2, poolID: poolID, amount: initialDeposit)
    
    // Record user2's shares
    let user2Details = getUserShareDetails(user2.address, poolID)
    let user2Shares = user2Details["shares"]!
    
    // User2 should have fewer shares (same deposit, higher share price)
    Test.assert(
        user2Shares < user1Shares,
        message: "User2 should have fewer shares than User1. User1: "
            .concat(user1Shares.toString())
            .concat(", User2: ").concat(user2Shares.toString())
    )
    
    // Re-fetch user1's details after yield was applied
    let user1DetailsAfterYield = getUserShareDetails(user1.address, poolID)
    let user1AssetValue = user1DetailsAfterYield["assetValue"]!
    
    // User1's asset value should now be > initial deposit (benefited from yield)
    Test.assert(
        user1AssetValue > initialDeposit,
        message: "User1 should have gained value from yield. Value: "
            .concat(user1AssetValue.toString())
    )
    
    // User2's asset value should be approximately their deposit
    let user2AssetValue = user2Details["assetValue"]!
    Test.assert(
        isWithinTolerance(user2AssetValue, initialDeposit, ACCEPTABLE_PRECISION_LOSS),
        message: "User2's asset value should match deposit. Value: "
            .concat(user2AssetValue.toString())
    )
}

// ============================================================================
// TEST: Minimum Amount Edge Cases
// ============================================================================

access(all) fun testVerySmallDeposit() {
    // Test deposit of very small amount (0.00001)
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.000001)
    let tinyAmount: UFix64 = 0.00001
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1.0)
    depositToPool(user, poolID: poolID, amount: tinyAmount)
    
    // Verify the deposit was recorded
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    Test.assert(
        isWithinTolerance(assetValue, tinyAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Asset value should match deposit. Expected: "
            .concat(tinyAmount.toString())
            .concat(", got: ").concat(assetValue.toString())
    )
    
    // Shares should be very close to deposit amount at 1.0 share price
    let shares = userDetails["shares"]!
    Test.assert(
        isWithinTolerance(shares, tinyAmount, ACCEPTABLE_PRECISION_LOSS),
        message: "Shares should match deposit at 1.0 price. Expected: "
            .concat(tinyAmount.toString())
            .concat(", Got: ").concat(shares.toString())
    )
}

access(all) fun testShareCalculationWithMinimumUFix64() {
    // Test what happens with the absolute minimum UFix64 value
    // This is a boundary test - the contract may reject this as below minimum deposit
    let poolID = createTestPoolWithMinDeposit(minDeposit: MINIMUM_DEPOSIT)
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1.0)
    
    // Attempt to deposit the minimum UFix64 amount
    depositToPool(user, poolID: poolID, amount: MINIMUM_DEPOSIT)
    
    // Verify the deposit was processed
    let info = getSharePricePrecisionInfo(poolID)
    let totalAssets = info["totalAssets"]!
    
    // Assets should include the minimum deposit
    Test.assert(
        totalAssets >= MINIMUM_DEPOSIT,
        message: "Total assets should include minimum deposit. Got: ".concat(totalAssets.toString())
    )
}

// ============================================================================
// TEST: Virtual Offset Protection
// ============================================================================

access(all) fun testVirtualOffsetsPreventDivisionByZero() {
    // Test that virtual offsets protect against division by zero with empty pool
    let poolID = createTestPoolWithShortInterval()
    
    // Query share price on empty pool (no deposits)
    let info = getSharePricePrecisionInfo(poolID)
    
    // Should return valid share price of 1.0, not panic
    let sharePrice = info["sharePrice"]!
    Test.assertEqual(1.0, sharePrice)
    
    // Effective values should be non-zero due to virtual offsets
    Test.assert(info["effectiveAssets"]! > 0.0, message: "effectiveAssets should be non-zero")
    Test.assert(info["effectiveShares"]! > 0.0, message: "effectiveShares should be non-zero")
}

access(all) fun testVirtualOffsetsMinimalDilution() {
    // Test that virtual offsets don't significantly dilute large deposits
    let poolID = createTestPoolWithShortInterval()
    let largeDeposit: UFix64 = 1000000.0  // 1 million
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: largeDeposit + 1.0)
    depositToPool(user, poolID: poolID, amount: largeDeposit)
    
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    
    // With virtual offsets of 0.0001, dilution should be ~0.00001% on 1M
    // assetValue should be essentially equal to deposit
    let dilutionPercent = absDifference(assetValue, largeDeposit) / largeDeposit * 100.0
    
    Test.assert(
        dilutionPercent < 0.0001,  // Less than 0.0001% dilution
        message: "Virtual offset dilution too high: "
            .concat(dilutionPercent.toString())
            .concat("% on large deposit")
    )
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
    
    // Both should have the same number of shares
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
    
    // Large user should have ~10x the shares of small user
    let ratio = largeDetails["shares"]! / smallDetails["shares"]!
    
    Test.assert(
        isWithinTolerance(ratio, 10.0, 0.0001),
        message: "Share ratio should be ~10:1. Got ratio: ".concat(ratio.toString())
    )
}

// ============================================================================
// TEST: Consistency Checks
// ============================================================================

access(all) fun testAssetsEqualsSharesTimesPrice() {
    // Invariant: totalAssets ≈ totalShares * sharePrice (accounting for virtual offsets)
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
    
    // assets / shares should equal sharePrice (approximately)
    // Actually: effectiveAssets / effectiveShares = sharePrice
    let calculatedPrice = info["effectiveAssets"]! / info["effectiveShares"]!
    
    Test.assert(
        isWithinTolerance(calculatedPrice, sharePrice, ACCEPTABLE_PRECISION_LOSS),
        message: "Calculated price doesn't match reported. Calculated: "
            .concat(calculatedPrice.toString())
            .concat(", Reported: ").concat(sharePrice.toString())
    )
}

access(all) fun testTotalStakedMatchesSumOfUserDeposits() {
    // Test that pool's totalStaked matches sum of individual user deposits
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
    let totalAllocatedFunds = info["totalAllocatedFunds"]!
    
    Test.assertEqual(expectedTotal, totalAllocatedFunds)
}

