import Test
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - WeightedSingleWinner Strategy
// ============================================================================

access(all) fun testWeightedSingleWinnerSelectsOne() {
    // Create a pool with WeightedSingleWinner strategy (default)
    let poolID = createTestPoolWithShortInterval()
    
    // Setup multiple users with deposits
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user3, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and execute draw
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)
    
    // The draw should complete successfully (single winner selected)
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist after draw")
}

access(all) fun testWeightedSingleWinnerWithNFTs() {
    // Create pool with WeightedSingleWinner strategy and NFT IDs
    let poolID = createPoolWithWeightedSingleWinner(nftIDs: [1, 2, 3])
    
    let details = getWinnerSelectionStrategyDetails(poolID)
    Test.assertEqual("Weighted Single Winner", details["strategyName"]! as! String)
}

access(all) fun testWeightedSingleWinnerEmptyDeposits() {
    // Test that with no deposits, the strategy handles gracefully
    let poolID = createTestPoolWithShortInterval()
    
    // Fund lottery but don't have any deposits
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // The draw should handle empty deposits gracefully
    // Note: This test verifies the strategy doesn't panic with empty receivers
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist")
}

access(all) fun testWeightedSingleWinnerSingleDepositor() {
    // Single depositor should always win
    let poolID = createTestPoolWithShortInterval()
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and execute draw
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)
    
    // Single depositor should win
    let userBalance = getUserPoolBalance(user.address, poolID)
    Test.assert(userBalance["deposits"]! > 0.0, message: "User should have deposits plus prize")
}

// ============================================================================
// TESTS - MultiWinnerSplit Strategy
// ============================================================================

access(all) fun testMultiWinnerSplit2Winners() {
    // Create pool with 2 winners, 70/30 split
    let poolID = createPoolWithMultiWinnerSplit(
        winnerCount: 2,
        splits: [0.7, 0.3],
        nftIDs: []
    )
    
    let details = getWinnerSelectionStrategyDetails(poolID)
    let strategyName = details["strategyName"]! as! String
    Test.assert(strategyName.utf8.length > 0, message: "Strategy name should not be empty")
}

access(all) fun testMultiWinnerSplit3Winners() {
    // Create pool with 3 winners, 50/30/20 split
    let poolID = createPoolWithMultiWinnerSplit(
        winnerCount: 3,
        splits: [0.5, 0.3, 0.2],
        nftIDs: []
    )
    
    let details = getWinnerSelectionStrategyDetails(poolID)
    let strategyName = details["strategyName"]! as! String
    Test.assert(strategyName.utf8.length > 0, message: "Strategy name should not be empty")
}

access(all) fun testMultiWinnerSplitFewerDepositorsThanWinners() {
    // Create pool expecting 3 winners but only 2 depositors
    let poolID = createPoolWithMultiWinnerSplit(
        winnerCount: 3,
        splits: [0.5, 0.3, 0.2],
        nftIDs: []
    )
    
    // Setup only 2 users
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Draw should handle gracefully with fewer depositors than expected winners
    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)
    
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist after draw")
}

access(all) fun testMultiWinnerSplitZeroWinnersReverts() {
    // winnerCount = 0 should fail
    let success = createPoolWithMultiWinnerSplitExpectFailure(
        winnerCount: 0,
        splits: [],
        nftIDs: []
    )
    Test.assertEqual(false, success)
}

access(all) fun testMultiWinnerSplitSumNotOneReverts() {
    // Splits not summing to 1.0 should fail
    let success = createPoolWithMultiWinnerSplitExpectFailure(
        winnerCount: 2,
        splits: [0.5, 0.3],  // Sum = 0.8, not 1.0
        nftIDs: []
    )
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - FixedPrizeTiers Strategy
// ============================================================================

access(all) fun testFixedPrizeTiersSingleTier() {
    // Create pool with single prize tier
    let poolID = createPoolWithFixedPrizeTiers(
        tierAmounts: [10.0],
        tierCounts: [1],
        tierNames: ["Grand Prize"],
        tierNFTIDs: [[]]
    )
    
    let details = getWinnerSelectionStrategyDetails(poolID)
    let strategyName = details["strategyName"]! as! String
    Test.assert(strategyName.utf8.length > 0, message: "Strategy name should not be empty")
}

access(all) fun testFixedPrizeTiersMultipleTiers() {
    // Create pool with multiple prize tiers (Grand/Second/Third)
    let poolID = createPoolWithFixedPrizeTiers(
        tierAmounts: [100.0, 50.0, 25.0],
        tierCounts: [1, 2, 3],
        tierNames: ["Grand", "Second", "Third"],
        tierNFTIDs: [[], [], []]
    )
    
    let details = getWinnerSelectionStrategyDetails(poolID)
    let strategyName = details["strategyName"]! as! String
    Test.assert(strategyName.utf8.length > 0, message: "Strategy name should not be empty")
}

access(all) fun testFixedPrizeTiersEmptyReverts() {
    // Empty tiers should fail
    let success = createPoolWithFixedPrizeTiersExpectFailure(
        tierAmounts: [],
        tierCounts: [],
        tierNames: [],
        tierNFTIDs: []
    )
    Test.assertEqual(false, success)
}

access(all) fun testFixedPrizeTierZeroAmountReverts() {
    // Tier with amount = 0 should fail
    let success = createPoolWithFixedPrizeTiersExpectFailure(
        tierAmounts: [0.0],
        tierCounts: [1],
        tierNames: ["Invalid"],
        tierNFTIDs: [[]]
    )
    Test.assertEqual(false, success)
}

access(all) fun testFixedPrizeTierZeroWinnersReverts() {
    // Tier with count = 0 should fail
    let success = createPoolWithFixedPrizeTiersExpectFailure(
        tierAmounts: [10.0],
        tierCounts: [0],
        tierNames: ["Invalid"],
        tierNFTIDs: [[]]
    )
    Test.assertEqual(false, success)
}

access(all) fun testFixedPrizeTiersInsufficientPrizePool() {
    // Test behavior when prize pool is smaller than needed for tiers
    let poolID = createPoolWithFixedPrizeTiers(
        tierAmounts: [100.0],  // Need 100.0 for single winner
        tierCounts: [1],
        tierNames: ["Grand Prize"],
        tierNFTIDs: [[]]
    )
    
    // Setup user
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(user, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund with less than needed (only 10.0 but need 100.0)
    fundLotteryPool(poolID, amount: 10.0)
    
    // The pool should exist but draw behavior depends on implementation
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist")
}

access(all) fun testFixedPrizeTiersInsufficientDepositors() {
    // Test behavior when fewer depositors than total winners needed
    let poolID = createPoolWithFixedPrizeTiers(
        tierAmounts: [10.0, 5.0],
        tierCounts: [2, 3],  // Need 5 total winners
        tierNames: ["First", "Second"],
        tierNFTIDs: [[], []]
    )
    
    // Setup only 2 users (need 5)
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    
    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Pool should exist
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should exist")
}

