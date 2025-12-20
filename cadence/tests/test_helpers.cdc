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
    deployContract(name: "PrizeWinnerTracker", path: "../contracts/PrizeWinnerTracker.cdc")
    deployContract(name: "PrizeSavings", path: "../contracts/PrizeSavings.cdc")
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
fun fundLotteryPool(_ poolID: UInt64, amount: UFix64) {
    let deployerAccount = getDeployerAccount()
    
    // Ensure deployer has funds
    fundAccountWithFlow(deployerAccount, amount: amount + 1.0)
    
    let fundResult = _executeTransaction(
        "../transactions/test/fund_lottery_pool.cdc",
        [poolID, amount],
        deployerAccount
    )
    assertTransactionSucceeded(fundResult, context: "Fund lottery pool")
}

// ============================================================================
// DRAW OPERATION HELPERS
// Note: Draw operations are admin-only. The account parameter is kept for
// backward compatibility but the deployer account is always used as the signer.
// 
// Draw flow: startDraw() → processDrawBatch() (repeat) → requestDrawRandomness() → completeDraw()
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
fun requestDrawRandomness(_ account: Test.TestAccount, poolID: UInt64) {
    // Draws are admin-only, so we always use the deployer account
    let deployerAccount = getDeployerAccount()
    let randomnessResult = _executeTransaction(
        "../transactions/test/request_draw_randomness.cdc",
        [poolID],
        deployerAccount
    )
    assertTransactionSucceeded(randomnessResult, context: "Request draw randomness")
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
fun executeFullDraw(_ account: Test.TestAccount, poolID: UInt64) {
    // 4-phase draw process:
    // 1. Start draw (transitions rounds, inits batch)
    startDraw(account, poolID: poolID)
    
    // 2. Process all batches (capture weights)
    // Use a large batch size to process all in one go for tests
    processAllDrawBatches(account, poolID: poolID, batchSize: 1000)
    
    // 3. Request randomness
    requestDrawRandomness(account, poolID: poolID)
    
    // 4. Wait for randomness and complete
    commitBlocksForRandomness()
    completeDraw(account, poolID: poolID)
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
fun createPoolWithDistribution(savings: UFix64, lottery: UFix64, treasury: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_pool_custom_distribution.cdc",
        [savings, lottery, treasury],
        deployerAccount
    )
    assertTransactionSucceeded(createResult, context: "Create pool with custom distribution")
    
    let poolCount = getPoolCount()
    return UInt64(poolCount - 1)
}

access(all)
fun createPoolWithDistributionExpectFailure(savings: UFix64, lottery: UFix64, treasury: UFix64): Bool {
    let deployerAccount = getDeployerAccount()
    let createResult = _executeTransaction(
        "../transactions/test/create_pool_custom_distribution.cdc",
        [savings, lottery, treasury],
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
fun updateDistributionStrategy(poolID: UInt64, savings: UFix64, lottery: UFix64, treasury: UFix64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/update_distribution_strategy.cdc",
        [poolID, savings, lottery, treasury],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Update distribution strategy")
}

access(all)
fun updateDrawInterval(poolID: UInt64, newInterval: UFix64) {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/update_draw_interval.cdc",
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
// WINNER TRACKER HELPERS
// ============================================================================

access(all)
fun poolHasWinnerTracker(_ poolID: UInt64): Bool {
    let scriptResult = _executeScript("../scripts/test/pool_has_winner_tracker.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! Bool
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
fun delegateUpdateDistributionStrategy(_ delegate: Test.TestAccount, poolID: UInt64, savings: UFix64, lottery: UFix64, treasury: UFix64): Bool {
    let result = _executeTransaction(
        "../transactions/test/delegate_update_distribution_strategy.cdc",
        [poolID, savings, lottery, treasury],
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

// Vault prefix constants for different pool creation methods
access(all) let VAULT_PREFIX_STANDARD: String = "testYieldVault_"
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
fun getPoolSavingsInfo(_ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_pool_savings_info.cdc", [poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

access(all)
fun getUserActualBalance(_ userAddress: Address, _ poolID: UInt64): {String: UFix64} {
    let scriptResult = _executeScript("../scripts/test/get_user_actual_balance.cdc", [userAddress, poolID])
    Test.expect(scriptResult, Test.beSucceeded())
    return scriptResult.returnValue! as! {String: UFix64}
}

