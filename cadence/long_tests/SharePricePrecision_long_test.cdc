import Test
import "PrizeSavings"
import "FlowToken"
import "../tests/test_helpers.cdc"

// ============================================================================
// SHARE PRICE PRECISION - LONG-RUNNING TESTS
// ============================================================================
// 
// These tests are separated from the main test suite because they involve
// many iterations (loops) or extreme values that take longer to execute.
// 
// Run with: flow test cadence/tests/ cadence/long_tests/
// ============================================================================

// ============================================================================
// CONSTANTS (duplicated from main test file)
// ============================================================================

access(all) let UFIX64_PRECISION: UFix64 = 0.00000001
access(all) let ACCEPTABLE_PRECISION_LOSS: UFix64 = 0.00000002
access(all) let PRECISION_VAULT_PREFIX: String = "testYieldVaultPrecision_"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Round-Trip Multiple Small Deposits (20 iterations)
// ============================================================================

access(all) fun testRoundTripMultipleSmallDeposits() {
    // Test that many small deposits don't accumulate significant error
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.001)
    let singleDeposit: UFix64 = 0.01
    let numDeposits: Int = 20
    let totalDeposit = singleDeposit * UFix64(numDeposits)
    
    // Create user with enough funds
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: totalDeposit + 2.0)
    
    // Make many small deposits
    var i = 0
    while i < numDeposits {
        depositToPool(user, poolID: poolID, amount: singleDeposit)
        i = i + 1
    }
    
    // Verify total balance
    let userDetails = getUserShareDetails(user.address, poolID)
    let assetValue = userDetails["assetValue"]!
    let deposits = userDetails["deposits"]!
    
    // Verify deposits were tracked correctly
    Test.assertEqual(totalDeposit, deposits)
    
    // Check accumulated precision loss (may be higher with many operations)
    let precisionLoss = userDetails["precisionLoss"]!
    let maxAcceptableLoss = ACCEPTABLE_PRECISION_LOSS * UFix64(numDeposits)
    
    Test.assert(
        precisionLoss <= maxAcceptableLoss,
        message: "Accumulated precision loss after "
            .concat(numDeposits.toString())
            .concat(" deposits too high: ").concat(precisionLoss.toString())
            .concat(", max acceptable: ").concat(maxAcceptableLoss.toString())
    )
}

// ============================================================================
// TEST: Share Price Stability with Many Deposits (10 users)
// ============================================================================

access(all) fun testSharePriceStabilityManyDeposits() {
    // Test that share price remains stable after many deposit operations
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 10.0
    let numUsers: Int = 10
    
    // Record initial share price
    let initialInfo = getSharePricePrecisionInfo(poolID)
    let initialSharePrice = initialInfo["sharePrice"]!
    
    // Many users make deposits
    var i = 0
    while i < numUsers {
        let user = Test.createAccount()
        setupUserWithFundsAndCollection(user, amount: depositAmount + 1.0)
        depositToPool(user, poolID: poolID, amount: depositAmount)
        i = i + 1
    }
    
    // Verify share price is still ~1.0 (no yield has occurred)
    let finalInfo = getSharePricePrecisionInfo(poolID)
    let finalSharePrice = finalInfo["sharePrice"]!
    
    // Share price should be very stable without yield
    Test.assert(
        isWithinTolerance(finalSharePrice, initialSharePrice, ACCEPTABLE_PRECISION_LOSS),
        message: "Share price drifted after many deposits. Initial: "
            .concat(initialSharePrice.toString())
            .concat(", Final: ").concat(finalSharePrice.toString())
    )
    
    // Verify totals are consistent
    let expectedTotalAssets = depositAmount * UFix64(numUsers)
    Test.assertEqual(expectedTotalAssets, finalInfo["totalAssets"]!)
    Test.assertEqual(expectedTotalAssets, finalInfo["totalShares"]!)
}

// ============================================================================
// TEST: EXTREME PRECISION LIMITS (100M+ values)
// ============================================================================

access(all) fun testExtremeBillionAssetsTinyShares() {
    // EXTREME TEST: Large assets with small shares ratio
    // Tests precision at high share prices
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    
    // Use a small deposit
    let smallDeposit: UFix64 = 1.0  // 1 FLOW = 1 share at price 1.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 2.0)
    depositToPool(user, poolID: poolID, amount: smallDeposit)
    
    // Record initial state
    let initialInfo = getSharePricePrecisionInfo(poolID)
    let initialShares = initialInfo["totalShares"]!
    log("Initial shares: ".concat(initialShares.toString()))
    
    // Simulate large yield - 100 million FLOW
    // With 70% savings: 70M assets / 1 share = 70M share price
    // Uses minting to bypass service account balance limitations
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let largeYield: UFix64 = 100000000.0  // 100 million
    
    simulateExtremeYieldAppreciation(poolIndex: poolIndex, amount: largeYield, vaultPrefix: "testYieldVaultPrecision_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Check extreme share price
    let extremeInfo = getSharePricePrecisionInfo(poolID)
    let extremeSharePrice = extremeInfo["sharePrice"]!
    let totalAssets = extremeInfo["totalAssets"]!
    let totalShares = extremeInfo["totalShares"]!
    
    log("Extreme share price: ".concat(extremeSharePrice.toString()))
    log("Total assets after 100M yield: ".concat(totalAssets.toString()))
    log("Total shares: ".concat(totalShares.toString()))
    
    // Share price should be very high
    // With 1 share and ~70M assets (70% of 100M): price ≈ 70 million per share
    Test.assert(
        extremeSharePrice > 50000000.0,  // At least 50 million per share
        message: "Extreme share price should be > 50M. Got: ".concat(extremeSharePrice.toString())
    )
    
    // Verify the math still works - assets ≈ shares * price
    let calculatedAssets = totalShares * extremeSharePrice
    let assetsDiff = absDifference(calculatedAssets, totalAssets + extremeInfo["virtualAssets"]!)
    
    log("Calculated assets from shares*price: ".concat(calculatedAssets.toString()))
    log("Actual effective assets: ".concat((totalAssets + extremeInfo["virtualAssets"]!).toString()))
    log("Difference: ".concat(assetsDiff.toString()))
    
    // User's value should have increased massively
    let userDetails = getUserShareDetails(user.address, poolID)
    let userValue = userDetails["assetValue"]!
    log("User asset value: ".concat(userValue.toString()))
    
    Test.assert(
        userValue > 50000000.0,  // User should have 50M+ in value
        message: "User value should be > 50M. Got: ".concat(userValue.toString())
    )
}

access(all) fun testExtremeSharePriceWithNewDeposit() {
    // Test: After share price becomes extreme, can a new user still deposit?
    // And do they get a fair number of shares?
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    
    // User 1 deposits tiny amount
    let user1 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 2.0)
    depositToPool(user1, poolID: poolID, amount: 0.01)
    
    // Massive yield to push share price up
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    let massiveYield: UFix64 = 100000000.0  // 100 million
    
    simulateYieldAppreciation(poolIndex: poolIndex, amount: massiveYield, vaultPrefix: "testYieldVaultPrecision_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    // Record share price before user2
    let preUser2Info = getSharePricePrecisionInfo(poolID)
    let highSharePrice = preUser2Info["sharePrice"]!
    log("Share price before user2: ".concat(highSharePrice.toString()))
    
    // User 2 deposits a large amount at high share price
    let user2 = Test.createAccount()
    let user2Deposit: UFix64 = 10000000.0  // 10 million FLOW
    setupUserWithFundsAndCollection(user2, amount: user2Deposit + 1.0)
    depositToPool(user2, poolID: poolID, amount: user2Deposit)
    
    // Check user2's shares
    let user2Details = getUserShareDetails(user2.address, poolID)
    let user2Shares = user2Details["shares"]!
    let user2Value = user2Details["assetValue"]!
    
    log("User2 shares: ".concat(user2Shares.toString()))
    log("User2 asset value: ".concat(user2Value.toString()))
    log("User2 deposit: ".concat(user2Deposit.toString()))
    
    // User2 should have received shares proportional to deposit/sharePrice
    // shares ≈ deposit / sharePrice
    let expectedShares = user2Deposit / highSharePrice
    log("Expected shares (approx): ".concat(expectedShares.toString()))
    
    // Shares should be non-zero (not rounded to zero)
    Test.assert(
        user2Shares > 0.0,
        message: "User2 should have received non-zero shares. Got: ".concat(user2Shares.toString())
    )
    
    // Asset value should be close to deposit (within precision tolerance)
    let valueDiff = absDifference(user2Value, user2Deposit)
    let tolerancePercent = valueDiff / user2Deposit * 100.0
    log("Value difference: ".concat(valueDiff.toString()))
    log("Tolerance percent: ".concat(tolerancePercent.toString()).concat("%"))
    
    // Allow up to 1% precision loss for extreme ratios
    Test.assert(
        tolerancePercent < 1.0,
        message: "User2 value precision loss > 1%. Loss: ".concat(tolerancePercent.toString()).concat("%")
    )
}

access(all) fun testSharePricePrecisionAtMaxUFix64Range() {
    // Test behavior approaching UFix64 limits
    // UFix64 max is approximately 184,467,440,737.09551615 (18.4 billion with 8 decimals)
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    
    // Deposit a small amount
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 2.0)
    depositToPool(user, poolID: poolID, amount: 1.0)
    
    // Push assets toward UFix64 limits with multiple large yields
    // Uses minting to bypass service account balance limitations
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    
    // Add 10 billion in yield (approaching but not exceeding UFix64 max)
    let hugeYield: UFix64 = 10000000000.0  // 10 billion
    
    simulateExtremeYieldAppreciation(poolIndex: poolIndex, amount: hugeYield, vaultPrefix: "testYieldVaultPrecision_")
    triggerSyncWithYieldSource(poolID: poolID)
    
    let info = getSharePricePrecisionInfo(poolID)
    let sharePrice = info["sharePrice"]!
    let totalAssets = info["totalAssets"]!
    
    log("Share price at 10B scale: ".concat(sharePrice.toString()))
    log("Total assets: ".concat(totalAssets.toString()))
    
    // Verify calculations still work at this scale
    // The effective price should be calculable
    let effectiveAssets = info["effectiveAssets"]!
    let effectiveShares = info["effectiveShares"]!
    let manualPrice = effectiveAssets / effectiveShares
    
    log("Manual price calculation: ".concat(manualPrice.toString()))
    
    // Prices should match
    Test.assert(
        isWithinTolerance(sharePrice, manualPrice, 0.00000001),
        message: "Share price mismatch at large scale. Reported: "
            .concat(sharePrice.toString())
            .concat(", Calculated: ").concat(manualPrice.toString())
    )
}

// ============================================================================
// TEST: 1000 Tiny Deposits vs One Large Deposit (SLOWEST)
// ============================================================================

access(all) fun testManyTinyDepositsVsOneLargeDeposit() {
    // Compare precision: many tiny deposits vs one large deposit
    // This tests if accumulated rounding errors affect fairness
    
    // Pool 1: One large deposit
    let pool1ID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    let largeAmount: UFix64 = 1000.0
    
    let largeUser = Test.createAccount()
    setupUserWithFundsAndCollection(largeUser, amount: largeAmount + 1.0)
    depositToPool(largeUser, poolID: pool1ID, amount: largeAmount)
    
    let largeUserDetails = getUserShareDetails(largeUser.address, pool1ID)
    let largeUserShares = largeUserDetails["shares"]!
    let largeUserValue = largeUserDetails["assetValue"]!
    
    // Pool 2: Many tiny deposits totaling same amount
    let pool2ID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    let tinyAmount: UFix64 = 0.001  // 0.001 per deposit
    let numDeposits: Int = 1000  // 1000 deposits = 1.0 total
    let totalTinyAmount = tinyAmount * UFix64(numDeposits)
    
    let tinyUser = Test.createAccount()
    setupUserWithFundsAndCollection(tinyUser, amount: totalTinyAmount + 1.0)
    
    var i = 0
    while i < numDeposits {
        depositToPool(tinyUser, poolID: pool2ID, amount: tinyAmount)
        i = i + 1
    }
    
    let tinyUserDetails = getUserShareDetails(tinyUser.address, pool2ID)
    let tinyUserShares = tinyUserDetails["shares"]!
    let tinyUserValue = tinyUserDetails["assetValue"]!
    
    log("Large user - Shares: ".concat(largeUserShares.toString()).concat(", Value: ").concat(largeUserValue.toString()))
    log("Tiny user (1000 deposits) - Shares: ".concat(tinyUserShares.toString()).concat(", Value: ").concat(tinyUserValue.toString()))
    
    // Calculate relative precision loss from many operations
    // Both should have shares proportional to their deposits
    let largeSharesPerAsset = largeUserShares / largeAmount
    let tinySharesPerAsset = tinyUserShares / totalTinyAmount
    
    log("Large user shares per asset: ".concat(largeSharesPerAsset.toString()))
    log("Tiny user shares per asset: ".concat(tinySharesPerAsset.toString()))
    
    // The ratio should be very close (within 0.01% for 1000 operations)
    let ratioDiff = absDifference(largeSharesPerAsset, tinySharesPerAsset)
    let ratioPercent = ratioDiff / largeSharesPerAsset * 100.0
    
    log("Ratio difference: ".concat(ratioPercent.toString()).concat("%"))
    
    // Many operations shouldn't create significant unfairness
    Test.assert(
        ratioPercent < 0.01,  // Less than 0.01% difference
        message: "Accumulated precision loss > 0.01%. Difference: ".concat(ratioPercent.toString()).concat("%")
    )
}

// ============================================================================
// TEST: Repeated Yield Distribution Stability (100 iterations)
// ============================================================================

access(all) fun testSharePriceStabilityUnderRepeatedYield() {
    // Test that repeated small yield distributions don't cause share price drift
    let poolID = createTestPoolWithMinDeposit(minDeposit: 0.00000001)
    
    // Initial deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1001.0)
    depositToPool(user, poolID: poolID, amount: 1000.0)
    
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    
    // Add yield in many small increments
    let smallYield: UFix64 = 0.1
    let numYields: Int = 100
    var totalYield: UFix64 = 0.0
    
    var i = 0
    while i < numYields {
        simulateYieldAppreciation(poolIndex: poolIndex, amount: smallYield, vaultPrefix: "testYieldVaultPrecision_")
        triggerSyncWithYieldSource(poolID: poolID)
        totalYield = totalYield + smallYield
        i = i + 1
    }
    
    let finalInfo = getSharePricePrecisionInfo(poolID)
    let finalAssets = finalInfo["totalAssets"]!
    let finalShares = finalInfo["totalShares"]!
    let finalPrice = finalInfo["sharePrice"]!
    
    log("After ".concat(numYields.toString()).concat(" yield events:"))
    log("Total yield added: ".concat(totalYield.toString()))
    log("Final assets: ".concat(finalAssets.toString()))
    log("Final shares: ".concat(finalShares.toString()))
    log("Final price: ".concat(finalPrice.toString()))
    
    // Verify invariant: effectiveAssets / effectiveShares = sharePrice
    let calculatedPrice = finalInfo["effectiveAssets"]! / finalInfo["effectiveShares"]!
    
    Test.assert(
        isWithinTolerance(finalPrice, calculatedPrice, ACCEPTABLE_PRECISION_LOSS),
        message: "Share price invariant violated after repeated yields. Reported: "
            .concat(finalPrice.toString())
            .concat(", Calculated: ").concat(calculatedPrice.toString())
    )
    
    // User's value should reflect the yield (70% goes to savings)
    let userDetails = getUserShareDetails(user.address, poolID)
    let userValue = userDetails["assetValue"]!
    let expectedMinValue = 1000.0 + (totalYield * 0.7 * 0.99)  // At least 99% of expected
    
    log("User value: ".concat(userValue.toString()))
    log("Expected min value: ".concat(expectedMinValue.toString()))
    
    Test.assert(
        userValue >= expectedMinValue,
        message: "User value less than expected after yields. Value: "
            .concat(userValue.toString())
            .concat(", Expected min: ").concat(expectedMinValue.toString())
    )
}

