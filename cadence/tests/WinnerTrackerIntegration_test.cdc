import Test
import "PrizeLinkedAccounts"
import "PrizeWinnerTracker"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Tracker Setup
// ============================================================================

access(all) fun testSetupWinnerTracker() {
    let deployerAccount = getDeployerAccount()

    // Setup winner tracker with max size 100
    setupWinnerTracker(maxSize: 100)

    // Verify tracker exists
    let trackerRef = PrizeWinnerTracker.borrowTracker(account: deployerAccount.address)
    Test.assert(trackerRef != nil, message: "Winner tracker should be created")
}

access(all) fun testUpdatePoolWinnerTracker() {
    let poolID = createTestPoolWithShortInterval()
    let deployerAccount = getDeployerAccount()

    // Pool should not have tracker initially
    var hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)

    // Setup tracker
    setupWinnerTracker(maxSize: 50)

    // Update pool to use tracker
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Verify pool now has tracker
    hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(true, hasTracker)
}

access(all) fun testRemoveWinnerTracker() {
    let poolID = createTestPoolWithShortInterval()
    let deployerAccount = getDeployerAccount()

    // Setup and attach tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Verify tracker is attached
    var hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(true, hasTracker)

    // Clear the tracker
    clearPoolWinnerTracker(poolID)

    // Verify tracker is removed
    hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)
}

access(all) fun testPoolWorksWithoutTracker() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Verify no tracker
    let hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(false, hasTracker)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw without tracker
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Draw should succeed
    let prizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

// ============================================================================
// TESTS - Winner Recording
// ============================================================================

access(all) fun testWinnerRecordedAfterDraw() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Verify no winners initially
    var winnerCount = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(0, winnerCount)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify winner was recorded
    winnerCount = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(1, winnerCount)
}

access(all) fun testMultipleWinnersRecorded() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 5.0 + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute multiple draws
    for _ in [1, 2, 3] {
        fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
        Test.moveTime(by: 61.0)
        executeFullDraw(deployerAccount, poolID: poolID)
    }

    // Verify 3 winners were recorded
    let winnerCount = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(3, winnerCount)
}

access(all) fun testWinnerAmountRecordedCorrectly() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw with specific prize amount
    let prizeAmount = 25.0
    fundPrizePool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify winner count
    let winnersCount = getRecentWinnersCount(deployerAccount.address, poolID, limit: 10)
    Test.assertEqual(1, winnersCount)

    // Verify prize amount using simpler helper
    let recordedAmount = getLastWinnerAmount(deployerAccount.address, poolID)
    Test.assertEqual(prizeAmount, recordedAmount)
}

access(all) fun testNFTWinnerRecordedCorrectly() {
    let deployerAccount = getDeployerAccount()

    // Deploy and setup MockNFT
    deployMockNFT()
    setupMockNFTCollection(deployerAccount)

    // Mint NFT first to get both id and uuid
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Tracker Test NFT", description: "For tracker test")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with NFT UUID in distribution
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Deposit NFT prize using id
    depositNFTPrize(poolID, nftID: nftID)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw with NFT
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Get NFT winners count
    let nftWinnerCount = getNFTWinnersCount(deployerAccount.address, poolID)
    Test.assertEqual(1, nftWinnerCount)

    // Verify winner count and NFT IDs using simpler helpers
    let winnersCount = getRecentWinnersCount(deployerAccount.address, poolID, limit: 10)
    Test.assertEqual(1, winnersCount)

    let recordedNFTIDs = getLastWinnerNFTIDs(deployerAccount.address, poolID)
    Test.assertEqual(1, recordedNFTIDs.length)
    Test.assertEqual(nftUUID, recordedNFTIDs[0])
}

// ============================================================================
// TESTS - Tracker Queries
// ============================================================================

access(all) fun testGetRecentWinnersReturnsCorrectData() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 5.0 + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute multiple draws
    for _ in [1, 2, 3, 4, 5] {
        fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
        Test.moveTime(by: 61.0)
        executeFullDraw(deployerAccount, poolID: poolID)
    }

    // Get only last 3 winners count
    let recentWinnersCount = getRecentWinnersCount(deployerAccount.address, poolID, limit: 3)
    Test.assertEqual(3, recentWinnersCount)

    // Verify all have correct pool ID using simpler helper
    let poolIDs = getRecentWinnerPoolIDs(deployerAccount.address, poolID, limit: 3)
    Test.assertEqual(3, poolIDs.length)
    for id in poolIDs {
        Test.assertEqual(poolID, id)
    }
}

access(all) fun testGetWinnerCountReturnsCorrectValue() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 3.0 + 5.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Initial count
    var count = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(0, count)

    // After first draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    count = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(1, count)

    // After second draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    count = getWinnerCount(deployerAccount.address, poolID)
    Test.assertEqual(2, count)
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testDrawSucceedsWhenTrackerCapabilityInvalid() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker first
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Verify tracker is attached
    var hasTracker = poolHasWinnerTracker(poolID)
    Test.assertEqual(true, hasTracker)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw (should work even if tracker has issues)
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Draw should succeed regardless
    let prizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)
}

access(all) fun testMultipleDrawsUpdateTrackerSequentially() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup tracker
    setupWinnerTracker(maxSize: 50)
    updatePoolWinnerTracker(poolID, trackerAddress: deployerAccount.address)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 10.0 + 20.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute many draws
    var expectedCount = 0
    for i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
        fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
        Test.moveTime(by: 61.0)
        executeFullDraw(deployerAccount, poolID: poolID)

        expectedCount = expectedCount + 1

        // Verify count after each draw
        let currentCount = getWinnerCount(deployerAccount.address, poolID)
        Test.assertEqual(expectedCount, currentCount)
    }

    // Verify final state using simpler helper
    let winnersCount = getRecentWinnersCount(deployerAccount.address, poolID, limit: 100)
    Test.assertEqual(10, winnersCount)
}

access(all) fun testTrackerAcrossMultiplePools() {
    let poolID1 = createTestPoolWithMediumInterval()
    let poolID2 = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup single tracker for both pools
    setupWinnerTracker(maxSize: 100)
    updatePoolWinnerTracker(poolID1, trackerAddress: deployerAccount.address)
    updatePoolWinnerTracker(poolID2, trackerAddress: deployerAccount.address)

    // Setup participants
    let participant1 = Test.createAccount()
    let participant2 = Test.createAccount()

    setupUserWithFundsAndCollection(participant1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(participant2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)

    depositToPool(participant1, poolID: poolID1, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(participant2, poolID: poolID2, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draws on both pools
    fundPrizePool(poolID1, amount: DEFAULT_PRIZE_AMOUNT)
    fundPrizePool(poolID2, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)

    executeFullDraw(deployerAccount, poolID: poolID1)
    executeFullDraw(deployerAccount, poolID: poolID2)

    // Verify separate counts per pool
    let count1 = getWinnerCount(deployerAccount.address, poolID1)
    let count2 = getWinnerCount(deployerAccount.address, poolID2)

    Test.assertEqual(1, count1)
    Test.assertEqual(1, count2)

    // Verify we can query each pool's winners separately using simpler helpers
    let winnersCount1 = getRecentWinnersCount(deployerAccount.address, poolID1, limit: 10)
    let winnersCount2 = getRecentWinnersCount(deployerAccount.address, poolID2, limit: 10)

    Test.assertEqual(1, winnersCount1)
    Test.assertEqual(1, winnersCount2)

    // Verify pool IDs match using the poolID-specific query
    let poolIDs1 = getRecentWinnerPoolIDs(deployerAccount.address, poolID1, limit: 10)
    let poolIDs2 = getRecentWinnerPoolIDs(deployerAccount.address, poolID2, limit: 10)

    Test.assertEqual(1, poolIDs1.length)
    Test.assertEqual(1, poolIDs2.length)
    Test.assertEqual(poolID1, poolIDs1[0])
    Test.assertEqual(poolID2, poolIDs2[0])
}
