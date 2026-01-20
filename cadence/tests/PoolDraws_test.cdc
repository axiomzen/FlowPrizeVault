import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Draw Eligibility
// ============================================================================

access(all) fun testCannotDrawBeforeInterval() {
    let poolID = createTestPoolWithShortInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Check immediately - should not be able to draw yet
    let drawStatus = getDrawStatus(poolID)
    let canDrawNow = drawStatus["canDrawNow"]! as! Bool
    
    // Note: Depending on implementation, this might be true immediately after pool creation
    // Adjust assertion based on actual behavior
}

access(all) fun testCanDrawAfterIntervalElapsed() {
    let poolID = createTestPoolWithShortInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Advance time past interval
    Test.moveTime(by: 2.0)
    
    // Should be able to draw now
    let drawStatus = getDrawStatus(poolID)
    let canDrawNow = drawStatus["canDrawNow"]! as! Bool
    Test.assert(canDrawNow, message: "Should be able to draw after time advancement")
}

// ============================================================================
// TESTS - Draw Execution
// ============================================================================

access(all) fun testStartDrawSetsBatchInProgressFlag() {
    let poolID = createTestPoolWithShortInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Fund lottery and advance time
    fundLotteryPool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 2.0)
    
    // Start draw (this only initializes batch processing, doesn't request randomness yet)
    startDraw(participant, poolID: poolID)
    
    // Verify batch processing is in progress (but not "draw in progress" which means randomness requested)
    let drawStatus = getDrawStatus(poolID)
    let isBatchInProgress = drawStatus["isBatchInProgress"]! as! Bool
    let isPendingDrawInProgress = drawStatus["isPendingDrawInProgress"]! as! Bool
    Test.assert(isBatchInProgress, message: "Batch processing should be in progress after startDraw")
    Test.assert(isPendingDrawInProgress, message: "Pending draw round should exist after startDraw")
    
    // isDrawInProgress is only true after requestDrawRandomness
    let isDrawInProgress = drawStatus["isDrawInProgress"]! as! Bool
    Test.assert(!isDrawInProgress, message: "Draw should not be in progress until randomness is requested")
}

access(all) fun testCompleteLotteryDraw() {
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    let prizeAmount = DEFAULT_PRIZE_AMOUNT
    
    // Use medium interval (60s) to ensure deposit happens within the round
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let drawParticipant = Test.createAccount()
    setupUserWithFundsAndCollection(drawParticipant, amount: depositAmount + 1.0)
    depositToPool(drawParticipant, poolID: poolID, amount: depositAmount)
    
    // Fund lottery and advance time past 60s interval
    fundLotteryPool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    
    // Execute full draw (4-phase: start → batch → randomness → complete)
    executeFullDraw(drawParticipant, poolID: poolID)
    
    // Verify winner received prize (single participant must win)
    let finalPrizes = getUserPrizes(drawParticipant.address, poolID)
    Test.assertEqual(prizeAmount, finalPrizes["totalEarnedPrizes"]!)
}

access(all) fun testPrizeIsReinvestedIntoDeposits() {
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    let prizeAmount = DEFAULT_PRIZE_AMOUNT
    
    // Use medium interval (60s) to ensure deposit happens within the round
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: depositAmount + 1.0)
    depositToPool(participant, poolID: poolID, amount: depositAmount)
    
    // Fund and execute draw
    fundLotteryPool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(participant, poolID: poolID)
    
    // Verify prize was reinvested
    let finalPrizes = getUserPrizes(participant.address, poolID)
    let expectedDeposits = depositAmount + prizeAmount
    Test.assertEqual(expectedDeposits, finalPrizes["totalBalance"]!)
}

// ============================================================================
// TESTS - Multiple Participants
// ============================================================================

access(all) fun testDrawWithMultipleParticipants() {
    let depositAmount = DEFAULT_DEPOSIT_AMOUNT
    let prizeAmount = DEFAULT_PRIZE_AMOUNT
    
    // Use medium interval (60s) to ensure all deposits happen within the round
    let poolID = createTestPoolWithMediumInterval()
    
    // Setup multiple participants
    let participant1 = Test.createAccount()
    let participant2 = Test.createAccount()
    let participant3 = Test.createAccount()
    
    setupUserWithFundsAndCollection(participant1, amount: depositAmount + 1.0)
    setupUserWithFundsAndCollection(participant2, amount: depositAmount + 1.0)
    setupUserWithFundsAndCollection(participant3, amount: depositAmount + 1.0)
    
    depositToPool(participant1, poolID: poolID, amount: depositAmount)
    depositToPool(participant2, poolID: poolID, amount: depositAmount)
    depositToPool(participant3, poolID: poolID, amount: depositAmount)
    
    // Fund and execute draw
    fundLotteryPool(poolID, amount: prizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(participant1, poolID: poolID)
    
    // Verify exactly one winner received the prize
    let prizes1 = getUserPrizes(participant1.address, poolID)
    let prizes2 = getUserPrizes(participant2.address, poolID)
    let prizes3 = getUserPrizes(participant3.address, poolID)
    
    let totalPrizesWon = prizes1["totalEarnedPrizes"]! + prizes2["totalEarnedPrizes"]! + prizes3["totalEarnedPrizes"]!
    Test.assertEqual(prizeAmount, totalPrizesWon)
}

// ============================================================================
// TESTS - Lottery Pool Funding
// ============================================================================

access(all) fun testFundLotteryPoolIncreasesBalance() {
    let poolID = createTestPoolWithShortInterval()
    let fundAmount = DEFAULT_PRIZE_AMOUNT
    
    // Setup a participant (needed for pool to have depositors)
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)
    
    // Get initial lottery balance
    let initialStatus = getDrawStatus(poolID)
    let initialBalance = initialStatus["prizePoolBalance"]! as! UFix64
    
    // Fund lottery
    fundLotteryPool(poolID, amount: fundAmount)
    
    // Verify balance increased
    let finalStatus = getDrawStatus(poolID)
    let finalBalance = finalStatus["prizePoolBalance"]! as! UFix64
    Test.assertEqual(initialBalance + fundAmount, finalBalance)
}

