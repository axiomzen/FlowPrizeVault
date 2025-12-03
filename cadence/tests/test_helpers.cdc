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
    deployContract(name: "TestHelpers", path: "../contracts/TestHelpers.cdc")
    deployContract(name: "PrizeSavings", path: "../contracts/PrizeSavings.cdc")
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
// ============================================================================

access(all)
fun startDraw(_ account: Test.TestAccount, poolID: UInt64) {
    let startResult = _executeTransaction(
        "../transactions/test/start_draw.cdc",
        [poolID],
        account
    )
    assertTransactionSucceeded(startResult, context: "Start draw")
}

access(all)
fun completeDraw(_ account: Test.TestAccount, poolID: UInt64) {
    let completeResult = _executeTransaction(
        "../transactions/test/complete_draw.cdc",
        [poolID],
        account
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
    startDraw(account, poolID: poolID)
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

