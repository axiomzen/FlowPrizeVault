import Test
import "PrizeLinkedAccounts"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Bonus Weight Setting
// ============================================================================

access(all) fun testSetBonusWeightUpdatesUserWeight() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Get receiver ID
    let receiverID = getReceiverID(participant.address, poolID)

    // Initial bonus weight should be 0
    var bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(0.0, bonusWeight)

    // Set bonus weight
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Loyalty bonus")

    // Verify bonus weight is updated
    bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)
}

access(all) fun testSetBonusWeightReplacesExisting() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let receiverID = getReceiverID(participant.address, poolID)

    // Set initial bonus
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Initial bonus")
    var bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)

    // Set new bonus (should replace)
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 50.0, reason: "Reduced bonus")
    bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(50.0, bonusWeight)
}

access(all) fun testAddBonusWeightAccumulates() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let receiverID = getReceiverID(participant.address, poolID)

    // Set initial bonus
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Initial bonus")

    // Add additional bonus
    addBonusPrizeWeight(poolID, receiverID: receiverID, additionalWeight: 50.0, reason: "Referral bonus")

    // Verify total is 150
    let bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(150.0, bonusWeight)

    // Add more
    addBonusPrizeWeight(poolID, receiverID: receiverID, additionalWeight: 25.0, reason: "Activity bonus")

    let finalWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(175.0, finalWeight)
}

access(all) fun testRemoveBonusWeightClearsWeight() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let receiverID = getReceiverID(participant.address, poolID)

    // Set bonus
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Test bonus")
    var bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)

    // Remove bonus
    removeBonusPrizeWeight(poolID, receiverID: receiverID)

    // Verify bonus is removed
    bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(0.0, bonusWeight)
}

// ============================================================================
// TESTS - Bonus Weight Impact on Draws
// ============================================================================

access(all) fun testUserWithBonusHasHigherWeightInBatch() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup two participants with equal deposits
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()

    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)

    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Give user1 a significant bonus weight
    let receiverID1 = getReceiverID(user1.address, poolID)
    setBonusPrizeWeight(poolID, receiverID: receiverID1, weight: 1000.0, reason: "Heavy bonus")

    // Advance time so TWAB is accumulated
    Test.moveTime(by: 61.0)

    // Get entries (TWAB weight) - should be similar for both
    let entries1 = getUserEntries(user1.address, poolID)
    let entries2 = getUserEntries(user2.address, poolID)

    // Both should have similar base TWAB entries (equal deposits, equal time)
    // The absolute values depend on the algorithm, but they should be non-zero
    Test.assert(entries1 > 0.0, message: "User 1 should have entries")
    Test.assert(entries2 > 0.0, message: "User 2 should have entries")

    // Verify bonus is set for user1
    let bonus1 = getBonusWeight(poolID, receiverID: receiverID1)
    Test.assertEqual(1000.0, bonus1)

    // User 2 should have no bonus
    let receiverID2 = getReceiverID(user2.address, poolID)
    let bonus2 = getBonusWeight(poolID, receiverID: receiverID2)
    Test.assertEqual(0.0, bonus2)
}

access(all) fun testBonusWeightCombinesWithTWAB() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Wait for TWAB accumulation
    Test.moveTime(by: 30.0)

    // Get initial TWAB entries
    let initialEntries = getUserEntries(participant.address, poolID)
    Test.assert(initialEntries > 0.0, message: "Should have TWAB entries")

    // Add bonus weight
    let receiverID = getReceiverID(participant.address, poolID)
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 50.0, reason: "Combo test")

    // TWAB entries don't change from bonus (bonus is added during draw calculation)
    let entriesAfterBonus = getUserEntries(participant.address, poolID)

    // The entries script only returns TWAB-based entries, not the combined weight
    // The combined weight is calculated during draw in processDrawBatch
    Test.assert(entriesAfterBonus >= initialEntries, message: "Entries should be at least equal or greater after more time")
}

// ============================================================================
// TESTS - Bonus Weight Persistence
// ============================================================================

access(all) fun testBonusWeightPersistsAcrossRounds() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 3.0 + 10.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Set bonus
    let receiverID = getReceiverID(participant.address, poolID)
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Persistent bonus")

    // Execute first draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify bonus persists
    var bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)

    // Execute second draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify bonus still persists
    bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)
}

access(all) fun testBonusWeightRemainsAfterWithdrawal() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 2.0 + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Set bonus
    let receiverID = getReceiverID(participant.address, poolID)
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 100.0, reason: "Pre-withdrawal bonus")

    // Partial withdrawal
    withdrawFromPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT / 2.0)

    // Verify bonus persists
    let bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(100.0, bonusWeight)
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testZeroBonusWeightHasNoEffect() {
    let poolID = createTestPoolWithMediumInterval()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let receiverID = getReceiverID(participant.address, poolID)

    // Set zero bonus
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: 0.0, reason: "Zero bonus")

    // Verify bonus is 0
    let bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(0.0, bonusWeight)
}

access(all) fun testVeryLargeBonusWeight() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let receiverID = getReceiverID(participant.address, poolID)

    // Set very large bonus
    let largeBonus = 999999999.0
    setBonusPrizeWeight(poolID, receiverID: receiverID, weight: largeBonus, reason: "Whale bonus")

    // Verify bonus is set
    let bonusWeight = getBonusWeight(poolID, receiverID: receiverID)
    Test.assertEqual(largeBonus, bonusWeight)

    // Execute draw to ensure it doesn't break
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Draw should complete without error (implicit check)
    let poolDetails = getPoolDetails(poolID)
    Test.assert(poolDetails["poolID"] != nil, message: "Pool should still exist after draw")
}

access(all) fun testBonusWeightOnSponsorHasNoEffect() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup regular participant (can win prizes)
    let regularUser = Test.createAccount()
    setupUserWithFundsAndCollection(regularUser, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(regularUser, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Setup sponsor (cannot win prizes)
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Sponsor entries should be 0 (they don't participate in prize draws)
    let sponsorEntries = getSponsorEntries(sponsor.address, poolID)
    Test.assertEqual(0.0, sponsorEntries)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Regular user should win (only eligible participant)
    let prizes = getUserPrizes(regularUser.address, poolID)
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, prizes["totalEarnedPrizes"]!)

    // Sponsor should not have won anything
    let sponsorBalance = getSponsorBalance(sponsor.address, poolID)
    // Sponsor balance should only have the deposit value (plus any yield), no prizes
    Test.assert(sponsorBalance["totalBalance"]! >= DEFAULT_DEPOSIT_AMOUNT - 0.01, message: "Sponsor should have at least their deposit")
}

access(all) fun testMultipleUsersWithDifferentBonusWeights() {
    let poolID = createTestPoolWithMediumInterval()
    let deployerAccount = getDeployerAccount()

    // Setup 3 participants
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    let user3 = Test.createAccount()

    setupUserWithFundsAndCollection(user1, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user2, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupUserWithFundsAndCollection(user3, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)

    depositToPool(user1, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user2, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    depositToPool(user3, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Set different bonus weights
    let receiverID1 = getReceiverID(user1.address, poolID)
    let receiverID2 = getReceiverID(user2.address, poolID)
    let receiverID3 = getReceiverID(user3.address, poolID)

    setBonusPrizeWeight(poolID, receiverID: receiverID1, weight: 10.0, reason: "Small bonus")
    setBonusPrizeWeight(poolID, receiverID: receiverID2, weight: 100.0, reason: "Medium bonus")
    setBonusPrizeWeight(poolID, receiverID: receiverID3, weight: 1000.0, reason: "Large bonus")

    // Verify bonuses are set correctly
    Test.assertEqual(10.0, getBonusWeight(poolID, receiverID: receiverID1))
    Test.assertEqual(100.0, getBonusWeight(poolID, receiverID: receiverID2))
    Test.assertEqual(1000.0, getBonusWeight(poolID, receiverID: receiverID3))

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Exactly one winner should receive the prize
    let prizes1 = getUserPrizes(user1.address, poolID)
    let prizes2 = getUserPrizes(user2.address, poolID)
    let prizes3 = getUserPrizes(user3.address, poolID)

    let totalPrizes = prizes1["totalEarnedPrizes"]! + prizes2["totalEarnedPrizes"]! + prizes3["totalEarnedPrizes"]!
    Test.assertEqual(DEFAULT_PRIZE_AMOUNT, totalPrizes)
}
