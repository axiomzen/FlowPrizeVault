import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// DECIMAL PRECISION TEST SUITE
// ============================================================================
//
// Tests decimal precision behavior when the yield connector truncates
// withdrawals to 6 decimal places, simulating EVM bridge behavior.
//
// Key areas tested:
// 1. Truncation utility correctness (inline reimplementation)
// 2. Full withdrawal through truncated connector
// 3. Multi-user dust isolation
// 4. Protocol fee + prize withdrawal through truncated connector
// 5. Sync stability under repeated deposit/withdraw cycles
// ============================================================================

// ============================================================================
// CONSTANTS
// ============================================================================

access(all) let UFIX64_PRECISION: UFix64 = 0.00000001
access(all) let ACCEPTABLE_DUST: UFix64 = 0.000001  // 1e-6 tolerance for truncation tests
access(all) let TRUNCATION_TOLERANCE: UFix64 = 0.01  // Up to 0.01 for 6-decimal truncation

// ============================================================================
// TRUNCATION UTILITY (mirrors FlowYieldVaultsConnectorV2.truncateToAssetPrecision)
// ============================================================================

/// Truncates a UFix64 value to 6 decimal places by flooring.
/// This is the same algorithm as FlowYieldVaultsConnectorV2.truncateToAssetPrecision().
access(all) fun truncateToSixDecimals(_ value: UFix64): UFix64 {
    if value == 0.0 { return 0.0 }

    let PRECISION_FACTOR: UFix64 = 1000000.0  // 10^6

    let integerPart: UFix64 = UFix64(UInt64(value))
    let fractionalPart: UFix64 = value - integerPart

    let scaledFrac: UFix64 = fractionalPart * PRECISION_FACTOR
    let truncatedFrac: UInt64 = UInt64(scaledFrac)

    return integerPart + UFix64(truncatedFrac) / PRECISION_FACTOR
}

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TEST: Truncation Utility Correctness
// ============================================================================

access(all) fun testTruncateNormalValue() {
    // 100.12345678 should become 100.123456
    let result = truncateToSixDecimals(100.12345678)
    Test.assertEqual(100.123456, result)
}

access(all) fun testTruncateSubPrecisionDust() {
    // 0.00000099 is below 6-decimal precision, should become 0.0
    let result = truncateToSixDecimals(0.00000099)
    Test.assertEqual(0.0, result)
}

access(all) fun testTruncateExactBoundary() {
    // 0.000001 is exactly the 6th decimal place, should be preserved
    let result = truncateToSixDecimals(0.000001)
    Test.assertEqual(0.000001, result)
}

access(all) fun testTruncateZero() {
    let result = truncateToSixDecimals(0.0)
    Test.assertEqual(0.0, result)
}

access(all) fun testTruncateLargeValue() {
    // Large value near practical limits - verify no overflow
    // UFix64 max is ~184467440737.09551615
    // Use a large but safe value
    let largeValue: UFix64 = 184467440737.09551615
    let result = truncateToSixDecimals(largeValue)
    // Should preserve integer part and truncate fractional to 6 decimals
    // 0.09551615 truncated to 6 decimals = 0.095516
    let expected: UFix64 = 184467440737.095516
    Test.assertEqual(expected, result)
}

access(all) fun testTruncateWholeNumber() {
    // Whole numbers should be unaffected
    let result = truncateToSixDecimals(42.0)
    Test.assertEqual(42.0, result)
}

access(all) fun testTruncateSixDecimalValue() {
    // Value already at 6 decimals should be unchanged
    let result = truncateToSixDecimals(1.234567)
    Test.assertEqual(1.234567, result)
}

// ============================================================================
// TEST: Full Withdrawal with Truncated Connector
// ============================================================================

access(all) fun testFullWithdrawThroughTruncatingConnector() {
    // Create pool with truncating connector (70/20/10 distribution)
    let poolID = createPoolWithTruncatingConnector(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    // Create user and deposit
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 110.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Simulate yield to create 8-decimal accounting artifacts
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_TRUNCATING)
    triggerSyncWithYieldSource(poolID: poolID)

    // Get user's balance before withdrawal
    let userDetails = getUserShareDetails(user.address, poolID)
    let shares = userDetails["shares"]!
    let assetValue = userDetails["assetValue"]!

    // Record FLOW balance before withdrawal
    let preWithdrawBalance = getUserFlowBalance(user.address)

    // Full withdraw
    withdrawFromPool(user, poolID: poolID, amount: assetValue)

    // Verify user is unregistered (0 shares)
    let postDetails = getUserShareDetails(user.address, poolID)
    Test.assertEqual(0.0, postDetails["shares"]!)

    // Verify user received funds (may lose up to truncation dust)
    let postWithdrawBalance = getUserFlowBalance(user.address)
    let received = postWithdrawBalance - preWithdrawBalance

    // User should receive close to their asset value, within truncation tolerance
    Test.assert(
        received > 0.0,
        message: "User should receive funds on withdrawal. Received: ".concat(received.toString())
    )
    Test.assert(
        isWithinTolerance(received, assetValue, TRUNCATION_TOLERANCE),
        message: "Received amount should be close to asset value. Expected ~"
            .concat(assetValue.toString())
            .concat(", got: ").concat(received.toString())
    )

    // Pool should have no negative accounting artifacts
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let totalShares = precisionInfo["totalShares"]!
    // After full withdrawal, total shares should be 0
    Test.assertEqual(0.0, totalShares)
}

// ============================================================================
// TEST: Multi-User Dust Isolation
// ============================================================================

access(all) fun testMultiUserDustIsolation() {
    // Two users deposit; one does full withdrawal; verify other's balance is unaffected
    let poolID = createPoolWithTruncatingConnector(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    setupUserWithFundsAndCollection(user2, amount: 110.0)

    // Both deposit the same amount
    depositToPool(user1, poolID: poolID, amount: 100.0)
    depositToPool(user2, poolID: poolID, amount: 100.0)

    // Simulate yield
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_TRUNCATING)
    triggerSyncWithYieldSource(poolID: poolID)

    // Record user2's balance before user1 withdraws
    let user2DetailsBefore = getUserShareDetails(user2.address, poolID)
    let user2SharesBefore = user2DetailsBefore["shares"]!
    let user2ValueBefore = user2DetailsBefore["assetValue"]!

    // User1 does full withdrawal
    let user1Details = getUserShareDetails(user1.address, poolID)
    withdrawFromPool(user1, poolID: poolID, amount: user1Details["assetValue"]!)

    // Verify user1 is unregistered
    let user1PostDetails = getUserShareDetails(user1.address, poolID)
    Test.assertEqual(0.0, user1PostDetails["shares"]!)

    // Verify user2's shares are unchanged
    let user2DetailsAfter = getUserShareDetails(user2.address, poolID)
    Test.assertEqual(user2SharesBefore, user2DetailsAfter["shares"]!)

    // User2's asset value should be similar (may differ slightly due to share price recalc)
    Test.assert(
        isWithinTolerance(user2DetailsAfter["assetValue"]!, user2ValueBefore, TRUNCATION_TOLERANCE),
        message: "User2's balance should be unaffected by user1's withdrawal. Before: "
            .concat(user2ValueBefore.toString())
            .concat(", After: ").concat(user2DetailsAfter["assetValue"]!.toString())
    )
}

// ============================================================================
// TEST: Protocol Fee + Prize Withdrawal Through Truncated Connector
// ============================================================================

access(all) fun testDrawCycleThroughTruncatingConnector() {
    // Full draw cycle with truncating connector should complete without panics
    let poolID = createPoolWithTruncatingConnector(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    // Setup users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupUserWithFundsAndCollection(user1, amount: 110.0)
    setupUserWithFundsAndCollection(user2, amount: 110.0)

    depositToPool(user1, poolID: poolID, amount: 50.0)
    depositToPool(user2, poolID: poolID, amount: 50.0)

    // Simulate yield that creates 8-decimal artifacts
    let poolCount = getPoolCount()
    let poolIndex = poolCount - 1
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 7.12345678, vaultPrefix: VAULT_PREFIX_TRUNCATING)
    triggerSyncWithYieldSource(poolID: poolID)

    // Wait for round to end
    Test.moveTime(by: 2.0)

    // Execute full draw cycle (should not panic even with truncation)
    executeFullDraw(user1, poolID: poolID)

    // Verify pool is still healthy after draw
    let precisionInfo = getSharePricePrecisionInfo(poolID)
    let totalShares = precisionInfo["totalShares"]!
    Test.assert(
        totalShares > 0.0,
        message: "Pool should still have shares after draw. Got: ".concat(totalShares.toString())
    )

    // Verify both users still have their positions
    let u1Details = getUserShareDetails(user1.address, poolID)
    let u2Details = getUserShareDetails(user2.address, poolID)
    Test.assert(u1Details["shares"]! > 0.0, message: "User1 should still have shares")
    Test.assert(u2Details["shares"]! > 0.0, message: "User2 should still have shares")
}

// ============================================================================
// TEST: Sync Stability Under Repeated Cycles
// ============================================================================

access(all) fun testSyncStabilityRepeatedCycles() {
    // Repeated deposit/withdraw cycles should not cause cascading deficit
    let poolID = createPoolWithTruncatingConnector(rewards: 0.7, prize: 0.2, protocolFee: 0.1)

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 1000.0)

    // Perform multiple deposit/withdraw cycles
    var cycle = 0
    while cycle < 5 {
        // Deposit
        depositToPool(user, poolID: poolID, amount: 100.0)

        // Simulate small yield to create truncation artifacts
        let poolCount = getPoolCount()
        let poolIndex = poolCount - 1
        simulateYieldAppreciation(poolIndex: poolIndex, amount: 1.12345678, vaultPrefix: VAULT_PREFIX_TRUNCATING)
        triggerSyncWithYieldSource(poolID: poolID)

        // Withdraw all
        let details = getUserShareDetails(user.address, poolID)
        let value = details["assetValue"]!
        if value > 0.0 {
            withdrawFromPool(user, poolID: poolID, amount: value)
        }

        // Verify no panic and pool is in consistent state
        let precisionInfo = getSharePricePrecisionInfo(poolID)
        let totalShares = precisionInfo["totalShares"]!
        Test.assertEqual(0.0, totalShares)

        cycle = cycle + 1
    }

    // Final deposit to verify pool is still operational
    depositToPool(user, poolID: poolID, amount: 50.0)
    let finalDetails = getUserShareDetails(user.address, poolID)
    Test.assert(
        finalDetails["shares"]! > 0.0,
        message: "Pool should still accept deposits after repeated cycles"
    )
    Test.assert(
        isWithinTolerance(finalDetails["assetValue"]!, 50.0, TRUNCATION_TOLERANCE),
        message: "Asset value should match deposit after repeated cycles. Got: "
            .concat(finalDetails["assetValue"]!.toString())
    )
}
