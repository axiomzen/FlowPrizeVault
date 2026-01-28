import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

access(all) fun setup() {
    deployAllDependencies()
}

access(all) fun boolToString(_ b: Bool): String {
    return b ? "true" : "false"
}

access(all) fun createPoolWithDrawInterval(_ intervalSeconds: UFix64): UInt64 {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/create_pool_custom_interval.cdc",
        [intervalSeconds],
        deployerAccount
    )
    assertTransactionSucceeded(result, context: "Create pool with custom interval")
    
    let poolCount = getPoolCount()
    log("Pool count after creation: ".concat(poolCount.toString()))
    return UInt64(poolCount - 1)
}

access(all) fun tryProcessDrawBatch(_ poolID: UInt64, limit: Int): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/process_draw_batch.cdc",
        [poolID, limit],
        deployerAccount
    )
    if result.error != nil {
        log("processDrawBatch error: ".concat(result.error!.message))
    }
    return result.error == nil
}

access(all) fun tryStartDraw(_ poolID: UInt64): Bool {
    let deployerAccount = getDeployerAccount()
    let result = _executeTransaction(
        "../transactions/test/start_draw.cdc",
        [poolID],
        deployerAccount
    )
    if result.error != nil {
        log("startDraw error: ".concat(result.error!.message))
    }
    return result.error == nil
}

access(all) fun testSingleUserOnly() {
    // Create pool with 1-hour interval
    let poolID = createPoolWithDrawInterval(3600.0)
    log("Created pool with ID: ".concat(poolID.toString()))
    
    // 60M shares
    let largeDeposit: UFix64 = 60000000.0
    
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: largeDeposit + 100.0)
    depositToPool(user, poolID: poolID, amount: largeDeposit)
    
    // Check registered receiver count
    let receiverCount = getRegisteredReceiverCount(poolID)
    log("Registered receiver count: ".concat(receiverCount.toString()))
    
    // Fund prize
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    
    // Check draw status before time advance
    let statusBefore = getDrawStatus(poolID)
    log("Can draw now (before time): ".concat(boolToString(statusBefore["canDrawNow"] as? Bool ?? false)))
    log("Is round ended (before time): ".concat(boolToString(statusBefore["isRoundEnded"] as? Bool ?? false)))
    
    // Advance time past draw interval
    Test.moveTime(by: 3601.0)
    
    // Check draw status after time advance
    let statusAfter = getDrawStatus(poolID)
    log("Can draw now (after time): ".concat(boolToString(statusAfter["canDrawNow"] as? Bool ?? false)))
    log("Is round ended (after time): ".concat(boolToString(statusAfter["isRoundEnded"] as? Bool ?? false)))
    
    // Start draw
    let startSuccess = tryStartDraw(poolID)
    log("Start draw result: ".concat(boolToString(startSuccess)))
    Test.assert(startSuccess, message: "Start draw should succeed")
    
    // Check batch progress
    let statusDuring = getDrawStatus(poolID)
    log("Is batch in progress: ".concat(boolToString(statusDuring["isBatchInProgress"] as? Bool ?? false)))
    log("Is batch complete: ".concat(boolToString(statusDuring["isBatchComplete"] as? Bool ?? false)))
    
    if let progress = statusDuring["batchProgress"] as? {String: AnyStruct}? {
        if let p = progress {
            log("Batch cursor: ".concat((p["cursor"] as? Int ?? -1).toString()))
            log("Batch total: ".concat((p["total"] as? Int ?? -1).toString()))
            log("Batch isComplete: ".concat(boolToString(p["isComplete"] as? Bool ?? false)))
        }
    }
    
    // Process batch
    let batchSuccess = tryProcessDrawBatch(poolID, limit: 1000)
    log("Process batch result: ".concat(boolToString(batchSuccess)))
    
    Test.assertEqual(true, batchSuccess)
    log("✓ Single user test passed")
}
