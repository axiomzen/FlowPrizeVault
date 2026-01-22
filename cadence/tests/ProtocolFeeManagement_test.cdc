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
// TESTS - Protocol Fee Recipient Configuration
// ============================================================================

access(all) fun testSetProtocolFeeRecipient() {
    // Create pool with protocol fee enabled (10% protocol fee)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Create a recipient account
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0) // Ensure they have a vault

    // Verify no recipient initially
    var currentRecipient = getProtocolFeeRecipient(poolID)
    Test.assertEqual(nil, currentRecipient)

    // Set protocol fee recipient
    setProtocolFeeRecipient(poolID, recipientAddress: recipient.address)

    // Verify recipient is set
    currentRecipient = getProtocolFeeRecipient(poolID)
    Test.assertEqual(recipient.address, currentRecipient!)
}

access(all) fun testClearProtocolFeeRecipient() {
    // Create pool with protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Create and set recipient
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    setProtocolFeeRecipient(poolID, recipientAddress: recipient.address)

    // Verify recipient is set
    var currentRecipient = getProtocolFeeRecipient(poolID)
    Test.assertEqual(recipient.address, currentRecipient!)

    // Clear the recipient
    clearProtocolFeeRecipient(poolID)

    // Verify recipient is cleared
    currentRecipient = getProtocolFeeRecipient(poolID)
    Test.assertEqual(nil, currentRecipient)
}

access(all) fun testRecipientPersistsAcrossDraws() {
    // Create pool with protocol fee (uses 24 hour interval)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Create and set recipient
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    setProtocolFeeRecipient(poolID, recipientAddress: recipient.address)

    // Setup participant and execute a draw
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    // Pool uses 86400 second (24 hour) draw interval
    Test.moveTime(by: 86401.0)

    let deployerAccount = getDeployerAccount()
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify recipient is still set after draw
    let currentRecipient = getProtocolFeeRecipient(poolID)
    Test.assertEqual(recipient.address, currentRecipient!)
}

// ============================================================================
// TESTS - Protocol Fee Accumulation (No Recipient)
// ============================================================================

access(all) fun testProtocolFeeAccumulatesWhenNoRecipient() {
    let deployerAccount = getDeployerAccount()

    // Create pool with 10% protocol fee and no recipient (uses 24 hour interval)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Simulate yield appreciation - protocol fee comes from yield, not prize pool
    let poolIndex = Int(poolID)
    let yieldAmount = 10.0
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)

    // Process rewards to allocate protocol fee
    processPoolRewards(poolID: poolID)

    // Fund prize pool and execute draw to transfer protocol fee to unclaimed vault
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    // Pool uses 86400 second (24 hour) draw interval
    Test.moveTime(by: 86401.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Get unclaimed protocol fee
    let unclaimedFee = getUnclaimedProtocolFee(poolID)

    // Protocol fee should be 10% of yield = 1.0 FLOW
    Test.assert(unclaimedFee > 0.0, message: "Unclaimed protocol fee should be greater than 0")
}

// ============================================================================
// TESTS - Unclaimed Protocol Fee Withdrawal
// ============================================================================

access(all) fun testAdminCanWithdrawUnclaimedProtocolFee() {
    let deployerAccount = getDeployerAccount()

    // Create pool with 10% protocol fee (uses 24 hour interval)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Simulate yield appreciation - protocol fee comes from yield
    let poolIndex = Int(poolID)
    let yieldAmount = 10.0
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)

    // Execute a draw to transfer protocol fee to unclaimed vault
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    // Pool uses 86400 second (24 hour) draw interval
    Test.moveTime(by: 86401.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Get initial unclaimed fee
    let initialFee = getUnclaimedProtocolFee(poolID)
    Test.assert(initialFee > 0.0, message: "Should have unclaimed protocol fee")

    // Create recipient and get their initial balance
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    let initialBalance = getUserFlowBalance(recipient.address)

    // Withdraw the unclaimed protocol fee
    withdrawUnclaimedProtocolFee(poolID, amount: initialFee, recipientAddress: recipient.address)

    // Verify unclaimed fee is now 0
    let remainingFee = getUnclaimedProtocolFee(poolID)
    Test.assertEqual(0.0, remainingFee)

    // Verify recipient received the fee
    let finalBalance = getUserFlowBalance(recipient.address)
    Test.assert(finalBalance > initialBalance, message: "Recipient balance should increase")
}

access(all) fun testWithdrawPartialProtocolFee() {
    let deployerAccount = getDeployerAccount()

    // Create pool with 10% protocol fee (uses 24 hour interval)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant and accumulate fees
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Simulate yield appreciation - protocol fee comes from yield
    let poolIndex = Int(poolID)
    let yieldAmount = 10.0
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)

    // Execute a draw to transfer protocol fee to unclaimed vault
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    // Pool uses 86400 second (24 hour) draw interval
    Test.moveTime(by: 86401.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    let totalFee = getUnclaimedProtocolFee(poolID)
    Test.assert(totalFee > 0.0, message: "Should have some protocol fee")

    // Withdraw only half
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    let withdrawAmount = totalFee / 2.0
    withdrawUnclaimedProtocolFee(poolID, amount: withdrawAmount, recipientAddress: recipient.address)

    // Verify remaining fee is approximately half
    let remainingFee = getUnclaimedProtocolFee(poolID)
    Test.assert(remainingFee > 0.0, message: "Should have remaining protocol fee")
    // Allow small precision tolerance
    Test.assert(isWithinTolerance(remainingFee, withdrawAmount, 0.00001), message: "Remaining fee should be approximately half")
}

access(all) fun testWithdrawMoreThanAvailableGetsActualAmount() {
    // Create pool with protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant and accumulate fees
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let yieldAmount = 10.0
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)

    let totalFee = getUnclaimedProtocolFee(poolID)

    // Try to withdraw more than available
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    let initialBalance = getUserFlowBalance(recipient.address)

    // Request 1000 FLOW but only totalFee is available
    withdrawUnclaimedProtocolFee(poolID, amount: 1000.0, recipientAddress: recipient.address)

    // Verify only the actual amount was withdrawn
    let remainingFee = getUnclaimedProtocolFee(poolID)
    Test.assertEqual(0.0, remainingFee)

    // Verify recipient received only the actual amount
    let finalBalance = getUserFlowBalance(recipient.address)
    let received = finalBalance - initialBalance
    Test.assert(isWithinTolerance(received, totalFee, 0.00001), message: "Should receive only the available amount")
}

access(all) fun testWithdrawFromEmptyVaultReturnsZero() {
    // Create pool with protocol fee but don't accumulate any
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant but don't generate yield
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Verify no unclaimed fee
    let initialFee = getUnclaimedProtocolFee(poolID)
    Test.assertEqual(0.0, initialFee)

    // Try to withdraw from empty vault
    let recipient = Test.createAccount()
    fundAccountWithFlow(recipient, amount: 1.0)
    let initialBalance = getUserFlowBalance(recipient.address)

    withdrawUnclaimedProtocolFee(poolID, amount: 1.0, recipientAddress: recipient.address)

    // Recipient balance should not change
    let finalBalance = getUserFlowBalance(recipient.address)
    Test.assertEqual(initialBalance, finalBalance)
}

// ============================================================================
// TESTS - Edge Cases
// ============================================================================

access(all) fun testProtocolFeeWithZeroPercentDistribution() {
    // Create pool with 0% protocol fee
    let poolID = createPoolWithDistribution(rewards: 0.6, prize: 0.4, protocolFee: 0.0)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Simulate yield
    let yieldAmount = 10.0
    let poolIndex = Int(poolID)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: yieldAmount, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)

    // Verify no protocol fee accumulated
    let unclaimedFee = getUnclaimedProtocolFee(poolID)
    Test.assertEqual(0.0, unclaimedFee)
}

access(all) fun testMultipleYieldDistributionsAccumulateProtocolFee() {
    let deployerAccount = getDeployerAccount()

    // Create pool with 10% protocol fee (uses 24 hour interval)
    let poolID = createPoolWithDistribution(rewards: 0.5, prize: 0.4, protocolFee: 0.1)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT * 3.0 + 5.0)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    let poolIndex = Int(poolID)

    // First yield + draw - protocol fee distribution
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 86401.0)
    executeFullDraw(deployerAccount, poolID: poolID)
    let firstFee = getUnclaimedProtocolFee(poolID)

    // Second yield + draw - additional protocol fee distribution
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_DISTRIBUTION)
    processPoolRewards(poolID: poolID)
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 86401.0)
    executeFullDraw(deployerAccount, poolID: poolID)
    let secondFee = getUnclaimedProtocolFee(poolID)

    // Fees should accumulate
    Test.assert(secondFee > firstFee, message: "Fees should accumulate across distributions")
}
