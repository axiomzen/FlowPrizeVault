import Test

// ============================================================================
// GLOBAL TEST CONSTANTS
// ============================================================================

access(all) let DEPLOYER_ADDRESS: Address = 0x0000000000000007
access(all) let DEFAULT_DEPOSIT_AMOUNT: UFix64 = 10.0
access(all) let DEFAULT_PRIZE_AMOUNT: UFix64 = 5.0
access(all) let DEFAULT_DRAW_INTERVAL: UFix64 = 86400.0
access(all) let SHORT_DRAW_INTERVAL: UFix64 = 1.0
access(all) let DEFAULT_MINIMUM_DEPOSIT: UFix64 = 1.0

// ============================================================================
// TRANSACTION EXECUTION HELPERS
// ============================================================================

access(all)
fun getDeployerAccount(): Test.TestAccount {
    return Test.getAccount(DEPLOYER_ADDRESS)
}

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

access(all)
fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )
    return Test.executeTransaction(txn)
}

access(all)
fun assertTransactionSucceeded(_ result: Test.TransactionResult, context: String) {
    if result.error != nil {
        log(context.concat(" error: ").concat(result.error!.message))
    }
    Test.expect(result, Test.beSucceeded())
}

// ============================================================================
// CONTRACT DEPLOYMENT HELPERS
// ============================================================================

access(all)
fun deployContract(name: String, path: String) {
    let deploymentError = Test.deployContract(
        name: name,
        path: path,
        arguments: []
    )
    Test.expect(deploymentError, Test.beNil())
}

access(all)
fun deployAllDependencies() {
    deployContract(name: "Xorshift128plus", path: "../../imports/45caec600164c9e6/Xorshift128plus.cdc")
    deployContract(name: "RandomConsumer", path: "../../imports/45caec600164c9e6/RandomConsumer.cdc")
    deployContract(name: "RandomBeaconHistory", path: "../../imports/e467b9dd11fa00df/RandomBeaconHistory.cdc")
    deployContract(name: "DeFiActionsUtils", path: "../../imports/92195d814edf9cb0/DeFiActionsUtils.cdc")
    deployContract(name: "DeFiActionsMathUtils", path: "../../imports/92195d814edf9cb0/DeFiActionsMathUtils.cdc")
    deployContract(name: "DeFiActions", path: "../../imports/92195d814edf9cb0/DeFiActions.cdc")
    deployContract(name: "PrizeLinkedAccounts", path: "../contracts/PrizeLinkedAccounts.cdc")
    deployContract(name: "MockYieldConnector", path: "../contracts/mock/MockYieldConnector.cdc")
}

// ============================================================================
// ACCOUNT SETUP HELPERS
// ============================================================================

access(all)
fun fundAccountWithFlow(_ account: Test.TestAccount, amount: UFix64) {
    let serviceAccount = Test.serviceAccount()
    let fundResult = _executeTransaction(
        "../transactions/test/fund_account.cdc",
        [account.address, amount],
        serviceAccount
    )
    assertTransactionSucceeded(fundResult, context: "Fund account")
}

access(all)
fun setupPoolPositionCollection(_ account: Test.TestAccount) {
    let setupResult = _executeTransaction(
        "../transactions/test/setup_user_collection.cdc",
        [],
        account
    )
    assertTransactionSucceeded(setupResult, context: "Setup collection")
}

access(all)
fun setupUserWithFundsAndCollection(_ account: Test.TestAccount, amount: UFix64) {
    fundAccountWithFlow(account, amount: amount)
    setupPoolPositionCollection(account)
}

access(all)
fun setupSponsorPositionCollection(_ account: Test.TestAccount) {
    let setupResult = _executeTransaction(
        "../transactions/prize-linked-accounts/setup_sponsor_collection.cdc",
        [],
        account
    )
    assertTransactionSucceeded(setupResult, context: "Setup sponsor collection")
}

access(all)
fun setupSponsorWithFundsAndCollection(_ account: Test.TestAccount, amount: UFix64) {
    fundAccountWithFlow(account, amount: amount)
    setupSponsorPositionCollection(account)
}

access(all)
fun sponsorDepositToPool(_ account: Test.TestAccount, poolID: UInt64, amount: UFix64) {
    let depositResult = _executeTransaction(
        "../transactions/prize-linked-accounts/sponsor_deposit.cdc",
        [poolID, amount],
        account
    )
    assertTransactionSucceeded(depositResult, context: "Sponsor deposit")
}

access(all)
fun sponsorWithdrawFromPool(_ account: Test.TestAccount, poolID: UInt64, amount: UFix64) {
    let withdrawResult = _executeTransaction(
        "../transactions/prize-linked-accounts/sponsor_withdraw.cdc",
        [poolID, amount],
        account
    )
    assertTransactionSucceeded(withdrawResult, context: "Sponsor withdraw")
}

// ============================================================================
// POOL OPERATION HELPERS
// ============================================================================

access(all)
fun createTestPool() {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_test_pool.cdc",
        [],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool")
}

access(all)
fun createTestPoolWithShortInterval(): UInt64 {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_test_pool_short_interval.cdc",
        [],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool with short interval")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createTestPoolWithMediumInterval(): UInt64 {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_test_pool_medium_interval.cdc",
        [],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool with medium interval (60s)")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun ensurePoolExists() {
    let poolCount = getPoolCount()
    if poolCount == 0 {
        createTestPool()
    }
}

// ============================================================================
// SCRIPT HELPERS - Pool Queries
// ============================================================================

access(all)
fun getAllPoolIDs(): [UInt64] {
    let scriptResult = _executeScript("../scripts/test/get_all_pool_ids.cdc", [])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! [UInt64]
}

access(all)
fun poolExists(_ poolID: UInt64): Bool {
    let scriptResult = _executeScript("../scripts/test/pool_exists.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Bool
}

access(all)
fun getPoolCount(): Int {
    let scriptResult = _executeScript("../scripts/test/get_pool_count.cdc", [])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Int
}

access(all)
fun getPoolTotals(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_pool_totals.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getPoolDetails(_ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_pool_details.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

access(all)
fun getDrawStatus(_ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_draw_status.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

// ============================================================================
// SCRIPT HELPERS - User Queries
// ============================================================================

access(all)
fun getUserPoolBalance(_ userAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_user_pool_balance.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserPrizes(_ userAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_user_prizes.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserEntries(_ userAddress: Address, _ poolID: UInt64): UFix64 {
    let scriptResult = _executeScript("../scripts/test/get_user_entries.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UFix64
}

access(all)
fun getDrawProgress(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_draw_progress.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserEntriesDebug(_ userAddress: Address, _ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_user_entries_debug.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

// ============================================================================
// SPONSOR QUERY HELPERS
// ============================================================================

access(all)
fun getSponsorBalance(_ sponsorAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_sponsor_balance.cdc", [sponsorAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getSponsorEntries(_ sponsorAddress: Address, _ poolID: UInt64): UFix64 {
    let scriptResult = _executeScript("../scripts/test/get_sponsor_entries.cdc", [sponsorAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UFix64
}

access(all)
fun isSponsor(_ poolID: UInt64, _ receiverID: UInt64): Bool {
    let scriptResult = _executeScript("../scripts/test/is_sponsor.cdc", [poolID, receiverID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Bool
}

access(all)
fun getSponsorCount(_ poolID: UInt64): Int {
    let scriptResult = _executeScript("../scripts/test/get_sponsor_count.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Int
}

access(all)
fun getRegisteredReceiverCount(_ poolID: UInt64): Int {
    let scriptResult = _executeScript("../scripts/test/get_registered_receiver_count.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Int
}

// ============================================================================
// USER ACTION HELPERS
// ============================================================================

access(all)
fun depositToPool(_ account: Test.TestAccount, poolID: UInt64, amount: UFix64) {
    let depositResult = _executeTransaction(
        "../transactions/test/deposit_to_pool.cdc",
        [poolID, amount],
        account
    )
    assertTransactionSucceeded(depositResult, context: "Deposit to pool")
}

access(all)
fun withdrawFromPool(_ account: Test.TestAccount, poolID: UInt64, amount: UFix64) {
    let withdrawResult = _executeTransaction(
        "../transactions/test/withdraw_from_pool.cdc",
        [poolID, amount],
        account
    )
    assertTransactionSucceeded(withdrawResult, context: "Withdraw from pool")
}

access(all)
fun fundPrizePool(_ poolID: UInt64, amount: UFix64) {
    let deployerAccount = getDeployerAccount()
    
    // Ensure deployer has funds
    fundAccountWithFlow(deployerAccount, amount: amount + 1.0)
    
    let fundResult = _executeTransaction(
        "../transactions/test/fund_prize_pool.cdc",
        [poolID, amount],
        deployerAccount
    )
    assertTransactionSucceeded(fundResult, context: "Fund prize pool")
}

// ============================================================================
// DRAW OPERATION HELPERS
// Note: Draw operations are admin-only. The account parameter is kept for
// backward compatibility but the deployer account is always used as the signer.
// 
// Draw flow (3 phases): startDraw() → processDrawBatch() (repeat) → completeDraw()
// Note: Randomness is requested during startDraw() and fulfilled during completeDraw().
// ============================================================================

access(all)
fun startDraw(_ account: Test.TestAccount, poolID: UInt64) {
    // Draws are admin-only, so we always use the deployer account
    let deployerAccount = getDeployerAccount()
    let startResult = _executeTransaction(
        "../transactions/test/start_draw.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(startResult, context: "Start draw")
}

access(all)
fun processDrawBatch(_ account: Test.TestAccount, poolID: UInt64, limit: Int) {
    // Draws are admin-only, so we always use the deployer account
    let deployerAccount = getDeployerAccount()
    let batchResult = _executeTransaction(
        "../transactions/test/process_draw_batch.cdc",
        [poolID, limit],
        deployerAccount
    )
    assertTransactionSucceeded(batchResult, context: "Process draw batch")
}

access(all)
fun processAllDrawBatches(_ account: Test.TestAccount, poolID: UInt64, batchSize: Int) {
    // Process batches until complete
    var remaining = 1  // Start with non-zero to enter loop
    var iterations = 0
    let maxIterations = 1000  // Safety limit
    
    while remaining > 0 && iterations < maxIterations {
        processDrawBatch(account, poolID: poolID, limit: batchSize)
        
        // Check if complete
        let drawStatus = getDrawStatus(poolID)
        let isComplete = drawStatus["isBatchComplete"] as? Bool ?? false
        if isComplete {
            remaining = 0
        }
        iterations = iterations + 1
    }
}

access(all)
fun completeDraw(_ account: Test.TestAccount, poolID: UInt64) {
    // Draws are admin-only, so we always use the deployer account
    let deployerAccount = getDeployerAccount()
    let completeResult = _executeTransaction(
        "../transactions/test/complete_draw.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(completeResult, context: "Complete draw")
}

access(all)
fun commitBlocksForRandomness() {
    Test.commitBlock()
    Test.commitBlock()
    Test.commitBlock()
}

access(all)
fun startNextRound(_ account: Test.TestAccount, poolID: UInt64) {
    // Starts next round, exiting intermission (admin-only)
    let deployerAccount = getDeployerAccount()
    let startResult = _executeTransaction(
        "../transactions/test/start_next_round.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(startResult, context: "Start next round")
}

access(all)
fun isInIntermission(_ poolID: UInt64): Bool {
    let drawStatus = getDrawStatus(poolID)
    return drawStatus["isIntermission"] as? Bool ?? false
}

// ============================================================================
// POOL STATE MACHINE HELPERS
// ============================================================================

/// Returns the current pool state as a string: "ROUND_ACTIVE", "AWAITING_DRAW", "DRAW_PROCESSING", "INTERMISSION"
access(all)
fun getPoolState(_ poolID: UInt64): String {
    let drawStatus = getDrawStatus(poolID)
    return drawStatus["poolState"] as? String ?? "UNKNOWN"
}

/// STATE 1: Round in progress, timer hasn't expired
access(all)
fun isRoundActive(_ poolID: UInt64): Bool {
    let drawStatus = getDrawStatus(poolID)
    return drawStatus["isRoundActive"] as? Bool ?? false
}

/// STATE 2: Round ended, waiting for startDraw()
access(all)
fun isAwaitingDraw(_ poolID: UInt64): Bool {
    let drawStatus = getDrawStatus(poolID)
    return drawStatus["isAwaitingDraw"] as? Bool ?? false
}

/// STATE 3: Draw ceremony in progress
access(all)
fun isDrawInProgress(_ poolID: UInt64): Bool {
    let drawStatus = getDrawStatus(poolID)
    return drawStatus["isDrawProcessing"] as? Bool ?? false  // Key name kept for backwards compat
}

/// Asserts exactly one of the 4 states is true (mutual exclusivity check)
access(all)
fun assertExactlyOneStateTrue(_ poolID: UInt64, context: String) {
    let roundActive = isRoundActive(poolID)
    let awaitingDraw = isAwaitingDraw(poolID)
    let drawProcessing = isDrawInProgress(poolID)
    let intermission = isInIntermission(poolID)

    var trueCount = 0
    if roundActive { trueCount = trueCount + 1 }
    if awaitingDraw { trueCount = trueCount + 1 }
    if drawProcessing { trueCount = trueCount + 1 }
    if intermission { trueCount = trueCount + 1 }

    Test.assertEqual(1, trueCount)
}

access(all)
fun executeFullDrawWithIntermission(_ account: Test.TestAccount, poolID: UInt64) {
    // 3-phase draw process that leaves pool in intermission:
    // 1. Start draw (transitions rounds, inits batch, requests randomness)
    startDraw(account, poolID: poolID)

    // 2. Process all batches (capture weights)
    // Use a large batch size to process all in one go for tests
    processAllDrawBatches(account, poolID: poolID, batchSize: 1000)

    // 3. Wait for randomness and complete
    commitBlocksForRandomness()
    completeDraw(account, poolID: poolID)

    // Pool is now in intermission - do NOT start next round
}

access(all)
fun executeFullDraw(_ account: Test.TestAccount, poolID: UInt64) {
    // 3-phase draw process with backwards compatibility:
    // 1. Start draw (transitions rounds, inits batch, requests randomness)
    startDraw(account, poolID: poolID)

    // 2. Process all batches (capture weights)
    // Use a large batch size to process all in one go for tests
    processAllDrawBatches(account, poolID: poolID, batchSize: 1000)

    // 3. Wait for randomness and complete
    commitBlocksForRandomness()
    completeDraw(account, poolID: poolID)

    // 4. Start next round (for backwards compatibility)
    // After completeDraw, pool is in intermission. Start next round automatically.
    startNextRound(account, poolID: poolID)
}

// ============================================================================
// SCRIPT HELPERS - Admin Queries
// ============================================================================

access(all)
fun checkAdminExists(_ address: Address): Bool {
    let scriptResult = _executeScript("../scripts/test/check_admin_exists.cdc", [address])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Bool
}

// ============================================================================
// DISTRIBUTION STRATEGY HELPERS
// ============================================================================

access(all)
fun createPoolWithDistribution(rewards: UFix64, prize: UFix64, protocolFee: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_pool_custom_distribution.cdc",
        [rewards, prize, protocolFee],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool with custom distribution")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithDistributionExpectFailure(rewards: UFix64, prize: UFix64, protocolFee: UFix64): Bool {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_pool_custom_distribution.cdc",
        [rewards, prize, protocolFee],
        deployerAccount
    )
    return createResult.error == nil
}

access(all)
fun getPoolDistributionDetails(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_pool_distribution_details.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun calculateDistribution(poolID: UInt64, totalAmount: UFix64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/calculate_distribution.cdc", [poolID, totalAmount])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getDistributionStrategyName(poolID: UInt64): String {
    let scriptResult = _executeScript("../scripts/test/get_distribution_strategy_name.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! String
}

// ============================================================================
// POOL INITIAL STATE HELPERS
// ============================================================================

access(all)
fun getPoolInitialState(_ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_pool_initial_state.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

// ============================================================================
// EMERGENCY STATE HELPERS
// ============================================================================

access(all)
fun getPoolEmergencyState(_ poolID: UInt64): UInt8 {
    let scriptResult = _executeScript("../scripts/test/get_pool_emergency_state.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UInt8
}

access(all)
fun enablePoolEmergencyMode(_ poolID: UInt64, reason: String) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/enable_emergency_mode.cdc",
        [poolID, reason],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Enable emergency mode")
}

access(all)
fun disablePoolEmergencyMode(_ poolID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/disable_emergency_mode.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Disable emergency mode")
}

access(all)
fun setPoolState(_ poolID: UInt64, state: UInt8, reason: String) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/set_pool_state.cdc",
        [poolID, state, reason],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Set pool state")
}

// ============================================================================
// PRIZE DISTRIBUTION HELPERS
// ============================================================================

access(all)
fun createPoolWithSingleWinnerPrize(nftIDs: [UInt64]): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_weighted_single_winner.cdc",
        [nftIDs],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with SingleWinnerPrize")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithPercentageSplit(splits: [UFix64], nftIDs: [UInt64]): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_multi_winner.cdc",
        [splits, nftIDs],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with PercentageSplit")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithPercentageSplitExpectFailure(splits: [UFix64], nftIDs: [UInt64]): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_multi_winner.cdc",
        [splits, nftIDs],
        deployerAccount
    )
    return result.error == nil
}

access(all)
fun createPoolWithFixedAmountTiers(tierAmounts: [UFix64], tierCounts: [Int], tierNames: [String], tierNFTIDs: [[UInt64]]): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_fixed_tiers.cdc",
        [tierAmounts, tierCounts, tierNames, tierNFTIDs],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with FixedAmountTiers")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithFixedAmountTiersExpectFailure(tierAmounts: [UFix64], tierCounts: [Int], tierNames: [String], tierNFTIDs: [[UInt64]]): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_fixed_tiers.cdc",
        [tierAmounts, tierCounts, tierNames, tierNFTIDs],
        deployerAccount
    )
    return result.error == nil
}

access(all)
fun getPrizeDistributionDetails(_ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_prize_distribution_details.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

// ============================================================================
// EMERGENCY CONFIG HELPERS
// ============================================================================

access(all)
fun createPoolWithEmergencyConfig(
    maxEmergencyDuration: UFix64,
    autoRecoveryEnabled: Bool,
    minYieldSourceHealth: UFix64,
    maxWithdrawFailures: Int,
    partialModeDepositLimit: UFix64,
    minBalanceThreshold: UFix64,
    minRecoveryHealth: UFix64
): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_custom_emergency_config.cdc",
        [maxEmergencyDuration, autoRecoveryEnabled, minYieldSourceHealth, maxWithdrawFailures, partialModeDepositLimit, minBalanceThreshold, minRecoveryHealth],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with custom emergency config")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithEmergencyConfigExpectFailure(
    maxEmergencyDuration: UFix64,
    autoRecoveryEnabled: Bool,
    minYieldSourceHealth: UFix64,
    maxWithdrawFailures: Int,
    partialModeDepositLimit: UFix64,
    minBalanceThreshold: UFix64,
    minRecoveryHealth: UFix64
): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_custom_emergency_config.cdc",
        [maxEmergencyDuration, autoRecoveryEnabled, minYieldSourceHealth, maxWithdrawFailures, partialModeDepositLimit, minBalanceThreshold, minRecoveryHealth],
        deployerAccount
    )
    return result.error == nil
}

access(all)
fun getEmergencyConfigDetails(_ poolID: UInt64): {String: AnyStruct} {
    let scriptResult = _executeScript("../scripts/test/get_emergency_config_details.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: AnyStruct}
}

// ============================================================================
// ADMIN OPERATION HELPERS
// ============================================================================

access(all)
fun updateDistributionStrategy(poolID: UInt64, rewards: UFix64, prize: UFix64, protocolFee: UFix64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/update_distribution_strategy.cdc",
        [poolID, rewards, prize, protocolFee],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Update distribution strategy")
}

access(all)
fun updateDrawInterval(poolID: UInt64, newInterval: UFix64) {
    // Updates draw interval for future rounds (current round is immutable once created)
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/update_draw_interval_both.cdc",
        [poolID, newInterval],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Update draw interval")
}

access(all)
fun updateMinimumDeposit(poolID: UInt64, newMinimum: UFix64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/update_minimum_deposit.cdc",
        [poolID, newMinimum],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Update minimum deposit")
}

access(all)
fun processPoolRewards(poolID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/process_pool_rewards.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Process pool rewards")
}

access(all)
fun createPoolAsNonAdmin(_ account: Test.TestAccount): Bool {
    let result = _executeTransaction(
        "../transactions/test/create_pool_as_non_admin.cdc",
        [],
        account
    )
    return result.error == nil
}

// ============================================================================
// ADMIN CAPABILITY HELPERS
// ============================================================================

// Issue capabilities (admin side)
access(all)
fun issueConfigOpsCapability(to delegateAddress: Address) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/issue_config_ops_capability.cdc",
        [delegateAddress],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Issue ConfigOps capability")
}

access(all)
fun issueCriticalOpsCapability(to delegateAddress: Address) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/issue_critical_ops_capability.cdc",
        [delegateAddress],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Issue CriticalOps capability")
}

access(all)
fun issueFullAdminCapability(to delegateAddress: Address) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/issue_full_admin_capability.cdc",
        [delegateAddress],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Issue full Admin capability")
}

// Claim capabilities (delegate side)
access(all)
fun claimConfigOpsCapability(_ delegate: Test.TestAccount) {
    let result = _executeTransaction(
        "../transactions/test/claim_config_ops_capability.cdc",
        [DEPLOYER_ADDRESS],
        delegate
    )
    assertTransactionSucceeded(result, context: "Claim ConfigOps capability")
}

access(all)
fun claimCriticalOpsCapability(_ delegate: Test.TestAccount) {
    let result = _executeTransaction(
        "../transactions/test/claim_critical_ops_capability.cdc",
        [DEPLOYER_ADDRESS],
        delegate
    )
    assertTransactionSucceeded(result, context: "Claim CriticalOps capability")
}

access(all)
fun claimFullAdminCapability(_ delegate: Test.TestAccount) {
    let result = _executeTransaction(
        "../transactions/test/claim_full_admin_capability.cdc",
        [DEPLOYER_ADDRESS],
        delegate
    )
    assertTransactionSucceeded(result, context: "Claim full Admin capability")
}

// Combined issue + claim helpers for convenience
access(all)
fun setupConfigOpsDelegate(_ delegate: Test.TestAccount) {
    issueConfigOpsCapability(to: delegate.address)
    claimConfigOpsCapability(delegate)
}

access(all)
fun setupCriticalOpsDelegate(_ delegate: Test.TestAccount) {
    issueCriticalOpsCapability(to: delegate.address)
    claimCriticalOpsCapability(delegate)
}

access(all)
fun setupFullAdminDelegate(_ delegate: Test.TestAccount) {
    issueFullAdminCapability(to: delegate.address)
    claimFullAdminCapability(delegate)
}

// Delegate operations with ConfigOps
access(all)
fun delegateUpdateDrawInterval(_ delegate: Test.TestAccount, poolID: UInt64, newInterval: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_update_draw_interval.cdc",
        [poolID, newInterval],
        delegate
    )
    return result.error == nil
}

access(all)
fun delegateUpdateMinimumDeposit(_ delegate: Test.TestAccount, poolID: UInt64, newMinimum: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_update_minimum_deposit.cdc",
        [poolID, newMinimum],
        delegate
    )
    return result.error == nil
}

access(all)
fun delegateProcessRewards(_ delegate: Test.TestAccount, poolID: UInt64): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_process_rewards.cdc",
        [poolID],
        delegate
    )
    return result.error == nil
}

// Delegate operations with CriticalOps
access(all)
fun delegateEnableEmergencyMode(_ delegate: Test.TestAccount, poolID: UInt64, reason: String): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_enable_emergency_mode.cdc",
        [poolID, reason],
        delegate
    )
    return result.error == nil
}

access(all)
fun delegateUpdateDistributionStrategy(_ delegate: Test.TestAccount, poolID: UInt64, rewards: UFix64, prize: UFix64, protocolFee: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_update_distribution_strategy.cdc",
        [poolID, rewards, prize, protocolFee],
        delegate
    )
    return result.error == nil
}

access(all)
fun delegateSetPoolState(_ delegate: Test.TestAccount, poolID: UInt64, state: UInt8, reason: String): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_set_pool_state.cdc",
        [poolID, state, reason],
        delegate
    )
    return result.error == nil
}

// Test that ConfigOps cannot call CriticalOps functions
access(all)
fun configOpsTryCriticalOperation(_ delegate: Test.TestAccount, poolID: UInt64, reason: String): Bool {
    let result = _executeTransaction(
        "../transactions/test/config_ops_try_critical_operation.cdc",
        [poolID, reason],
        delegate
    )
    return result.error == nil
}

// Test that CriticalOps cannot call ConfigOps functions
access(all)
fun criticalOpsTryConfigOperation(_ delegate: Test.TestAccount, poolID: UInt64, newInterval: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/critical_ops_try_config_operation.cdc",
        [poolID, newInterval],
        delegate
    )
    return result.error == nil
}

// Full admin delegate operations
access(all)
fun fullAdminDelegateUpdateDrawInterval(_ delegate: Test.TestAccount, poolID: UInt64, newInterval: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/full_admin_update_draw_interval.cdc",
        [poolID, newInterval],
        delegate
    )
    return result.error == nil
}

access(all)
fun fullAdminDelegateEnableEmergency(_ delegate: Test.TestAccount, poolID: UInt64, reason: String): Bool {
    let result = _executeTransaction(
        "../transactions/test/full_admin_enable_emergency.cdc",
        [poolID, reason],
        delegate
    )
    return result.error == nil
}

// ============================================================================
// YIELD SOURCE SIMULATION HELPERS
// ============================================================================

// Vault prefix constant for pool creation methods
access(all) let VAULT_PREFIX_DISTRIBUTION: String = "testYieldVaultDist_"

access(all)
fun simulateYieldAppreciation(poolIndex: Int, amount: UFix64, vaultPrefix: String) {
    let deployerAccount = getDeployerAccount()
    
    // Ensure deployer has funds
    fundAccountWithFlow(deployerAccount, amount: amount + 1.0)
    
    let result = _executeTransaction(
        "../transactions/test/add_yield_to_pool_vault.cdc",
        [poolIndex, amount, vaultPrefix],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Simulate yield appreciation")
}

access(all)
fun simulateYieldDepreciation(poolIndex: Int, amount: UFix64, vaultPrefix: String) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/simulate_yield_depreciation.cdc",
        [poolIndex, amount, vaultPrefix],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Simulate yield depreciation")
}

access(all)
fun simulateYieldDepreciationExpectFailure(poolIndex: Int, amount: UFix64, vaultPrefix: String): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/simulate_yield_depreciation.cdc",
        [poolIndex, amount, vaultPrefix],
        deployerAccount
    )
    return result.error == nil
}

access(all)
fun triggerSyncWithYieldSource(poolID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/process_pool_rewards.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Trigger syncWithYieldSource")
}

access(all)
fun getPoolRewardsInfo(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_pool_rewards_info.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserActualBalance(_ userAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_user_actual_balance.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

// ============================================================================
// PRECISION TESTING HELPERS
// ============================================================================

access(all)
fun getSharePricePrecisionInfo(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_share_price_precision_info.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserShareDetails(_ userAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_user_share_details.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

/// Get a user's FLOW token wallet balance (not pool balance)
access(all)
fun getUserFlowBalance(_ userAddress: Address): UFix64 {
    let scriptResult = _executeScript("../scripts/test/get_user_flow_balance.cdc", [userAddress])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UFix64
}

/// Create a pool with a very small minimum deposit for precision testing
access(all)
fun createTestPoolWithMinDeposit(minDeposit: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_test_pool_custom_min_deposit.cdc",
        [minDeposit],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool with custom min deposit")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

/// Helper to calculate absolute difference between two UFix64 values
access(all)
fun absDifference(_ a: UFix64, _ b: UFix64): UFix64 {
    if a > b {
        return a - b
    }
    return b - a
}

/// Helper to check if a value is within tolerance of expected value
access(all)
fun isWithinTolerance(_ actual: UFix64, _ expected: UFix64, _ tolerance: UFix64): Bool {
    let diff = absDifference(actual, expected)
    return diff <= tolerance
}

// ============================================================================
// EXTREME AMOUNT TESTING HELPERS (Minting)
// ============================================================================

/// Mints FLOW tokens to an account (for extreme test scenarios)
/// Uses service account's FlowToken.Administrator to mint unlimited tokens
/// This bypasses the balance limitation of the service account
access(all)
fun mintFlowToAccount(_ account: Test.TestAccount, amount: UFix64) {
    let serviceAccount = Test.serviceAccount()
    let mintResult = _executeTransaction(
        "../transactions/test/mint_flow_to_account.cdc",
        [account.address, amount],
        serviceAccount
    )
    assertTransactionSucceeded(mintResult, context: "Mint FLOW to account")
}

/// Simulates yield appreciation using minted tokens (for extreme amounts)
/// Use this instead of simulateYieldAppreciation when testing with billions of FLOW
access(all)
fun simulateExtremeYieldAppreciation(poolIndex: Int, amount: UFix64, vaultPrefix: String) {
    let deployerAccount = getDeployerAccount()

    // Mint tokens instead of transferring from limited balance
    mintFlowToAccount(deployerAccount, amount: amount + 1.0)

    let result = _executeTransaction(
        "../transactions/test/add_yield_to_pool_vault.cdc",
        [poolIndex, amount, vaultPrefix],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Simulate extreme yield appreciation")
}

// ============================================================================
// ADMIN CLEANUP HELPERS
// ============================================================================

access(all)
fun cleanupPoolStaleEntries(_ poolID: UInt64, startIndex: Int, receiverLimit: Int): {String: Int} {
    let deployerAccount = getDeployerAccount()
    let cleanupResult = _executeTransaction(
        "../transactions/test/cleanup_pool_stale_entries.cdc",
        [poolID, startIndex, receiverLimit],
        deployerAccount
    )
    assertTransactionSucceeded(cleanupResult, context: "Cleanup pool stale entries")
    
    // Return a placeholder - actual counts are logged but not returned to test
    return {"ghostReceivers": 0, "userShares": 0, "pendingNFTClaims": 0, "nextIndex": 0, "totalReceivers": 0}
}

access(all)
fun cleanupPoolStaleEntriesExpectFailure(_ poolID: UInt64, startIndex: Int, receiverLimit: Int): Test.TransactionResult {
    let deployerAccount = getDeployerAccount()
    let txn = Test.Transaction(
        code: Test.readFile("../transactions/test/cleanup_pool_stale_entries.cdc"),
        authorizers: [deployerAccount.address],
        signers: [deployerAccount],
        arguments: [poolID, startIndex, receiverLimit]
    )
    return Test.executeTransaction(txn)
}

// ============================================================================
// NFT PRIZE MANAGEMENT HELPERS
// ============================================================================

/// Deploy the MockNFT contract for testing
access(all)
fun deployMockNFT() {
    deployContract(name: "MockNFT", path: "../contracts/mock/MockNFT.cdc")
}

/// Mint a MockNFT and return its ID (for deposit) and UUID (for pool config)
/// Returns {"id": UInt64, "uuid": UInt64}
access(all)
fun mintMockNFTWithUUID(recipient: Test.TestAccount, name: String, description: String): {String: UInt64} {
    let deployerAccount = getDeployerAccount()

    // Get the NFT IDs BEFORE minting to find the new one after
    let idsBefore = getMockNFTIDs(recipient.address)

    let mintResult = _executeTransaction(
        "../transactions/test/mint_mock_nft.cdc",
        [recipient.address, name, description],
        deployerAccount
    )
    assertTransactionSucceeded(mintResult, context: "Mint mock NFT")

    // Get the NFT IDs AFTER minting
    let idsAfter = getMockNFTIDs(recipient.address)

    // Find the new ID (the one in idsAfter but not in idsBefore)
    var newID: UInt64 = 0
    for id in idsAfter {
        var found = false
        for beforeID in idsBefore {
            if id == beforeID {
                found = true
                break
            }
        }
        if !found {
            newID = id
            break
        }
    }

    // Get the uuid of this NFT
    let uuid = getMockNFTUUID(recipient.address, newID)

    return {"id": newID, "uuid": uuid}
}

/// Setup a MockNFT collection for a user
access(all)
fun setupMockNFTCollection(_ account: Test.TestAccount) {
    let setupResult = _executeTransaction(
        "../transactions/test/setup_mock_nft_collection.cdc",
        [],
        account
    )
    assertTransactionSucceeded(setupResult, context: "Setup MockNFT collection")
}

/// Get MockNFT IDs owned by an account
access(all)
fun getMockNFTIDs(_ address: Address): [UInt64] {
    let scriptResult = _executeScript("../scripts/test/get_mock_nft_ids.cdc", [address])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! [UInt64]
}

/// Get the uuid of a MockNFT by its id
access(all)
fun getMockNFTUUID(_ ownerAddress: Address, _ nftID: UInt64): UInt64 {
    let scriptResult = _executeScript("../scripts/test/get_mock_nft_uuid.cdc", [ownerAddress, nftID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UInt64
}

/// Deposit an NFT prize to a pool (admin operation)
access(all)
fun depositNFTPrize(_ poolID: UInt64, nftID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let depositResult = _executeTransaction(
        "../transactions/test/deposit_nft_prize.cdc",
        [poolID, nftID],
        deployerAccount
    )
    assertTransactionSucceeded(depositResult, context: "Deposit NFT prize")
}

/// Withdraw an unassigned NFT prize from a pool (admin operation)
access(all)
fun withdrawNFTPrize(_ poolID: UInt64, nftID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let withdrawResult = _executeTransaction(
        "../transactions/test/withdraw_nft_prize.cdc",
        [poolID, nftID],
        deployerAccount
    )
    assertTransactionSucceeded(withdrawResult, context: "Withdraw NFT prize")
}

/// Withdraw an NFT prize expecting failure
access(all)
fun withdrawNFTPrizeExpectFailure(_ poolID: UInt64, nftID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/withdraw_nft_prize.cdc",
        [poolID, nftID],
        deployerAccount
    )
    return result.error == nil
}

/// Claim a pending NFT prize as a user
access(all)
fun claimPendingNFT(_ account: Test.TestAccount, poolID: UInt64, nftIndex: Int) {
    let claimResult = _executeTransaction(
        "../transactions/test/claim_nft_prize.cdc",
        [poolID, nftIndex],
        account
    )
    assertTransactionSucceeded(claimResult, context: "Claim pending NFT")
}

/// Claim a pending NFT expecting failure
access(all)
fun claimPendingNFTExpectFailure(_ account: Test.TestAccount, poolID: UInt64, nftIndex: Int): Bool {
    let result = _executeTransaction(
        "../transactions/test/claim_nft_prize.cdc",
        [poolID, nftIndex],
        account
    )
    return result.error == nil
}

/// Get the count of pending NFT claims for a user
access(all)
fun getPendingNFTCount(_ userAddress: Address, _ poolID: UInt64): Int {
    let scriptResult = _executeScript("../scripts/test/get_pending_nft_count.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Int
}

/// Get the IDs of pending NFT claims for a user
access(all)
fun getPendingNFTIDs(_ userAddress: Address, _ poolID: UInt64): [UInt64] {
    let scriptResult = _executeScript("../scripts/test/get_pending_nft_ids.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! [UInt64]
}

/// Get the count of available NFT prizes in a pool
access(all)
fun getNFTPrizeCount(_ poolID: UInt64): Int {
    let scriptResult = _executeScript("../scripts/test/get_nft_prize_count.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Int
}

/// Get the available NFT prize IDs in a pool
access(all)
fun getAvailableNFTPrizeIDs(_ poolID: UInt64): [UInt64] {
    let scriptResult = _executeScript("../scripts/test/get_available_nft_prize_ids.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! [UInt64]
}

/// Create a pool with NFT prize IDs specified in the distribution (60s interval)
access(all)
fun createPoolWithNFTPrizes(nftIDs: [UInt64]): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_with_nft_prizes.cdc",
        [nftIDs],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with NFT prizes")

    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

// ============================================================================
// PROTOCOL FEE MANAGEMENT HELPERS
// ============================================================================

/// Set the protocol fee recipient for a pool (requires OwnerOnly entitlement)
access(all)
fun setProtocolFeeRecipient(_ poolID: UInt64, recipientAddress: Address) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/set_protocol_fee_recipient.cdc",
        [poolID, recipientAddress],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Set protocol fee recipient")
}

/// Clear the protocol fee recipient (set to nil)
access(all)
fun clearProtocolFeeRecipient(_ poolID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/clear_protocol_fee_recipient.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Clear protocol fee recipient")
}

/// Withdraw unclaimed protocol fee from a pool
access(all)
fun withdrawUnclaimedProtocolFee(_ poolID: UInt64, amount: UFix64, recipientAddress: Address): UFix64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/withdraw_unclaimed_protocol_fee.cdc",
        [poolID, amount, recipientAddress],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Withdraw unclaimed protocol fee")

    // Return the actual withdrawn amount
    let feeInfo = getUnclaimedProtocolFee(poolID)
    return amount // Simplified - actual amount may differ
}

/// Get the unclaimed protocol fee balance for a pool
access(all)
fun getUnclaimedProtocolFee(_ poolID: UInt64): UFix64 {
    let scriptResult = _executeScript("../scripts/test/get_unclaimed_protocol_fee.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UFix64
}

/// Get protocol fee recipient address for a pool (nil if not set)
access(all)
fun getProtocolFeeRecipient(_ poolID: UInt64): Address? {
    let scriptResult = _executeScript("../scripts/test/get_protocol_fee_recipient.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue as! Address?
}

// ============================================================================
// BONUS WEIGHT MANAGEMENT HELPERS
// ============================================================================

/// Set bonus prize weight for a user (replaces existing)
access(all)
fun setBonusPrizeWeight(_ poolID: UInt64, receiverID: UInt64, weight: UFix64, reason: String) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/set_bonus_weight.cdc",
        [poolID, receiverID, weight, reason],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Set bonus prize weight")
}

/// Add to existing bonus prize weight
access(all)
fun addBonusPrizeWeight(_ poolID: UInt64, receiverID: UInt64, additionalWeight: UFix64, reason: String) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/add_bonus_weight.cdc",
        [poolID, receiverID, additionalWeight, reason],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Add bonus prize weight")
}

/// Remove all bonus weight from a user
access(all)
fun removeBonusPrizeWeight(_ poolID: UInt64, receiverID: UInt64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/remove_bonus_weight.cdc",
        [poolID, receiverID],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Remove bonus prize weight")
}

/// Get a user's bonus weight for a pool
access(all)
fun getBonusWeight(_ poolID: UInt64, receiverID: UInt64): UFix64 {
    let scriptResult = _executeScript("../scripts/test/get_bonus_weight.cdc", [poolID, receiverID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UFix64
}

/// Get a user's receiver ID for a pool
access(all)
fun getReceiverID(_ userAddress: Address, _ poolID: UInt64): UInt64 {
    let scriptResult = _executeScript("../scripts/test/get_receiver_id.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! UInt64
}

// ============================================================================
// ROUND TARGET END TIME HELPERS
// ============================================================================

/// Update the current round's target end time (extend or shorten the round)
access(all)
fun updateRoundTargetEndTime(_ poolID: UInt64, newTargetEndTime: UFix64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/prize-linked-accounts/update_round_target_end_time.cdc",
        [poolID, newTargetEndTime],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Update round target end time")
}

/// Update round target end time and expect failure (for testing error cases)
access(all)
fun updateRoundTargetEndTimeExpectFailure(_ poolID: UInt64, newTargetEndTime: UFix64): Test.TransactionResult {
    let deployerAccount = getDeployerAccount()
    let txn = Test.Transaction(
        code: Test.readFile("../transactions/prize-linked-accounts/update_round_target_end_time.cdc"),
        authorizers: [deployerAccount.address],
        signers: [deployerAccount],
        arguments: [poolID, newTargetEndTime]
    )
    return Test.executeTransaction(txn)
}

/// Get the current round's target end time
access(all)
fun getRoundTargetEndTime(_ poolID: UInt64): UFix64 {
    let status = getDrawStatus(poolID)
    return status["targetEndTime"] as? UFix64 ?? 0.0
}

