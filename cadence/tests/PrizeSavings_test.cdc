import Test
import "PrizeSavings"
import "FlowToken"

// Admin account will deploy PrizeSavings and own the Admin resource
access(all) let adminAccount = Test.createAccount()
access(all) let userAccount = Test.createAccount()

access(all) fun setup() {
    // Deploy all dependencies first (shared contracts)
    var err = Test.deployContract(
        name: "Xorshift128plus",
        path: "../../imports/45caec600164c9e6/Xorshift128plus.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "RandomConsumer",
        path: "../../imports/45caec600164c9e6/RandomConsumer.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "RandomBeaconHistory",
        path: "../../imports/e467b9dd11fa00df/RandomBeaconHistory.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../imports/92195d814edf9cb0/DeFiActionsUtils.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../imports/92195d814edf9cb0/DeFiActionsMathUtils.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../imports/92195d814edf9cb0/DeFiActions.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    // Deploy PrizeWinnerTracker contract
    err = Test.deployContract(
        name: "PrizeWinnerTracker",
        path: "../contracts/PrizeWinnerTracker.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    // Deploy MockYieldConnector contract (for mock connectors)
    err = Test.deployContract(
        name: "MockYieldConnector",
        path: "../contracts/mock/MockYieldConnector.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    // Deploy PrizeSavings contract
    err = Test.deployContract(
        name: "PrizeSavings",
        path: "../contracts/PrizeSavings.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())
}

// Test that contract deploys correctly with no pools
access(all) fun testContractDeployed() {
    let poolIDs = PrizeSavings.getAllPoolIDs()
    Test.assertEqual(0, poolIDs.length)
}

// Test that storage paths are correctly configured
access(all) fun testStoragePathsConfigured() {
    Test.assertEqual(/storage/PrizeSavingsCollection, PrizeSavings.PoolPositionCollectionStoragePath)
    Test.assertEqual(/public/PrizeSavingsCollection, PrizeSavings.PoolPositionCollectionPublicPath)
    Test.assertEqual(/storage/PrizeSavingsAdmin, PrizeSavings.AdminStoragePath)
}

// Test creating a pool and verifying it exists
access(all) fun testCreatePoolAndVerify() {
    // Read and execute the create pool transaction
    let createPoolCode = Test.readFile("../transactions/test/create_test_pool.cdc")
    
    // The contract is deployed to the address specified in flow.json for "testing" network
    // PrizeSavings is at 0x0000000000000007
    let deployerAddress: Address = 0x0000000000000007
    let deployerAccount = Test.getAccount(deployerAddress)
    
    // Log for debugging
    log("Service account address: ".concat(Test.serviceAccount().address.toString()))
    log("Deployer account address: ".concat(deployerAccount.address.toString()))
    
    // Execute with the deployer account (which deployed PrizeSavings and owns the Admin resource)
    let txResult = Test.executeTransaction(
        Test.Transaction(
            code: createPoolCode,
            authorizers: [deployerAccount.address],
            signers: [deployerAccount],
            arguments: []
        )
    )
    
    // Log transaction result for debugging
    if txResult.error != nil {
        log("Transaction error: ".concat(txResult.error!.message))
    }
    
    Test.expect(txResult, Test.beSucceeded())
    
    // Verify the pool was created using a script (to ensure same contract instance)
    let getPoolsScript = Test.readFile("../scripts/test/get_pool_count.cdc")
    let scriptResult = Test.executeScript(getPoolsScript, [])
    Test.expect(scriptResult, Test.beSucceeded())
    
    let poolCount = scriptResult.returnValue! as! Int
    Test.assertEqual(1, poolCount)
    
    // Also verify pool details via script
    let getPoolScript = Test.readFile("../scripts/test/get_pool_details.cdc")
    let detailsResult = Test.executeScript(getPoolScript, [0 as UInt64])
    Test.expect(detailsResult, Test.beSucceeded())
    
    let details = detailsResult.returnValue! as! {String: AnyStruct}
    Test.assertEqual(1.0, details["minimumDeposit"]! as! UFix64)
    Test.assertEqual(86400.0, details["drawIntervalSeconds"]! as! UFix64)
}

// Test that borrowPool returns nil for non-existent pool
access(all) fun testBorrowNonExistentPool() {
    let pool = PrizeSavings.borrowPool(poolID: 999)
    Test.expect(pool, Test.beNil())
}

// Test creating a PoolPositionCollection
access(all) fun testCreatePoolPositionCollection() {
    let collection <- PrizeSavings.createPoolPositionCollection()
    
    // Verify it starts empty
    let registeredPools = collection.getRegisteredPoolIDs()
    Test.assertEqual(0, registeredPools.length)
    
    destroy collection
}

// Test user deposit into pool
access(all) fun testUserDeposit() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 10.0
    
    // Get the deployer account (needed for pool creation if not exists)
    let deployerAddress: Address = 0x0000000000000007
    let deployerAccount = Test.getAccount(deployerAddress)
    
    // First, ensure a pool exists by checking pool count
    let getPoolsScript = Test.readFile("../scripts/test/get_pool_count.cdc")
    let poolCountResult = Test.executeScript(getPoolsScript, [])
    Test.expect(poolCountResult, Test.beSucceeded())
    let poolCount = poolCountResult.returnValue! as! Int
    
    // Create pool if it doesn't exist
    if poolCount == 0 {
        let createPoolCode = Test.readFile("../transactions/test/create_test_pool.cdc")
        let createResult = Test.executeTransaction(
            Test.Transaction(
                code: createPoolCode,
                authorizers: [deployerAccount.address],
                signers: [deployerAccount],
                arguments: []
            )
        )
        Test.expect(createResult, Test.beSucceeded())
    }
    
    // Get initial pool totals
    let getPoolTotalsScript = Test.readFile("../scripts/test/get_pool_totals.cdc")
    let initialTotalsResult = Test.executeScript(getPoolTotalsScript, [poolID])
    Test.expect(initialTotalsResult, Test.beSucceeded())
    let initialTotals = initialTotalsResult.returnValue! as! {String: UFix64}
    let initialDeposited = initialTotals["totalDeposited"]!
    let initialStaked = initialTotals["totalStaked"]!
    
    log("Initial pool totalDeposited: ".concat(initialDeposited.toString()))
    log("Initial pool totalStaked: ".concat(initialStaked.toString()))
    
    // Fund user account with FlowToken from service account (which has tokens in testing)
    let fundAccountCode = Test.readFile("../transactions/test/fund_account.cdc")
    let serviceAccount = Test.serviceAccount()
    log("Service account address: ".concat(serviceAccount.address.toString()))
    
    let fundResult = Test.executeTransaction(
        Test.Transaction(
            code: fundAccountCode,
            authorizers: [serviceAccount.address],
            signers: [serviceAccount],
            arguments: [userAccount.address, depositAmount + 1.0]  // Extra for fees
        )
    )
    
    if fundResult.error != nil {
        log("Fund error: ".concat(fundResult.error!.message))
    }
    Test.expect(fundResult, Test.beSucceeded())
    log("Funded user account with FlowToken")
    
    // Set up user's PoolPositionCollection
    let setupCollectionCode = Test.readFile("../transactions/test/setup_user_collection.cdc")
    let setupResult = Test.executeTransaction(
        Test.Transaction(
            code: setupCollectionCode,
            authorizers: [userAccount.address],
            signers: [userAccount],
            arguments: []
        )
    )
    Test.expect(setupResult, Test.beSucceeded())
    log("Set up user's PoolPositionCollection")
    
    // Deposit into the pool
    let depositCode = Test.readFile("../transactions/test/deposit_to_pool.cdc")
    let depositResult = Test.executeTransaction(
        Test.Transaction(
            code: depositCode,
            authorizers: [userAccount.address],
            signers: [userAccount],
            arguments: [poolID, depositAmount]
        )
    )
    
    if depositResult.error != nil {
        log("Deposit error: ".concat(depositResult.error!.message))
    }
    Test.expect(depositResult, Test.beSucceeded())
    log("Deposit transaction succeeded")
    
    // Verify pool totals increased
    let finalTotalsResult = Test.executeScript(getPoolTotalsScript, [poolID])
    Test.expect(finalTotalsResult, Test.beSucceeded())
    let finalTotals = finalTotalsResult.returnValue! as! {String: UFix64}
    let finalDeposited = finalTotals["totalDeposited"]!
    let finalStaked = finalTotals["totalStaked"]!
    
    log("Final pool totalDeposited: ".concat(finalDeposited.toString()))
    log("Final pool totalStaked: ".concat(finalStaked.toString()))
    
    Test.assertEqual(initialDeposited + depositAmount, finalDeposited)
    Test.assertEqual(initialStaked + depositAmount, finalStaked)
    
    // Verify user's balance in the pool
    let getUserBalanceScript = Test.readFile("../scripts/test/get_user_pool_balance.cdc")
    let userBalanceResult = Test.executeScript(getUserBalanceScript, [userAccount.address, poolID])
    Test.expect(userBalanceResult, Test.beSucceeded())
    let userBalance = userBalanceResult.returnValue! as! {String: UFix64}
    
    log("User deposits: ".concat(userBalance["deposits"]!.toString()))
    log("User totalEarnedPrizes: ".concat(userBalance["totalEarnedPrizes"]!.toString()))
    log("User savingsEarned: ".concat(userBalance["savingsEarned"]!.toString()))
    
    // Verify user's deposit amount is correct
    Test.assertEqual(depositAmount, userBalance["deposits"]!)
    Test.assertEqual(0.0, userBalance["totalEarnedPrizes"]!)
    Test.assertEqual(0.0, userBalance["savingsEarned"]!)  // No yield yet
}

// Test lottery draw functionality
access(all) fun testLotteryDraw() {
    let depositAmount: UFix64 = 10.0
    let prizeAmount: UFix64 = 5.0
    
    // Get the deployer account (for admin operations)
    let deployerAddress: Address = 0x0000000000000007
    let deployerAccount = Test.getAccount(deployerAddress)
    let serviceAccount = Test.serviceAccount()
    
    // Step 1: Create a new pool with SHORT draw interval for testing
    log("Step 1: Creating pool with short draw interval...")
    let createPoolCode = Test.readFile("../transactions/test/create_test_pool_short_interval.cdc")
    let createResult = Test.executeTransaction(
        Test.Transaction(
            code: createPoolCode,
            authorizers: [deployerAccount.address],
            signers: [deployerAccount],
            arguments: []
        )
    )
    if createResult.error != nil {
        log("Create pool error: ".concat(createResult.error!.message))
    }
    Test.expect(createResult, Test.beSucceeded())
    
    // Get the new pool ID (should be the latest one)
    let getPoolsScript = Test.readFile("../scripts/test/get_pool_count.cdc")
    let poolCountResult = Test.executeScript(getPoolsScript, [])
    Test.expect(poolCountResult, Test.beSucceeded())
    let poolCount = poolCountResult.returnValue! as! Int
    let poolID: UInt64 = UInt64(poolCount - 1)  // Latest pool
    log("Created pool ID: ".concat(poolID.toString()))
    
    // Step 2: Create a second user for the draw test
    let drawUserAccount = Test.createAccount()
    
    // Fund the draw user account
    let fundAccountCode = Test.readFile("../transactions/test/fund_account.cdc")
    let fundResult = Test.executeTransaction(
        Test.Transaction(
            code: fundAccountCode,
            authorizers: [serviceAccount.address],
            signers: [serviceAccount],
            arguments: [drawUserAccount.address, depositAmount + 1.0]
        )
    )
    Test.expect(fundResult, Test.beSucceeded())
    log("Step 2: Funded draw user account")
    
    // Step 3: Set up user's collection and make a deposit
    let setupCollectionCode = Test.readFile("../transactions/test/setup_user_collection.cdc")
    let setupResult = Test.executeTransaction(
        Test.Transaction(
            code: setupCollectionCode,
            authorizers: [drawUserAccount.address],
            signers: [drawUserAccount],
            arguments: []
        )
    )
    Test.expect(setupResult, Test.beSucceeded())
    
    let depositCode = Test.readFile("../transactions/test/deposit_to_pool.cdc")
    let depositResult = Test.executeTransaction(
        Test.Transaction(
            code: depositCode,
            authorizers: [drawUserAccount.address],
            signers: [drawUserAccount],
            arguments: [poolID, depositAmount]
        )
    )
    if depositResult.error != nil {
        log("Deposit error: ".concat(depositResult.error!.message))
    }
    Test.expect(depositResult, Test.beSucceeded())
    log("Step 3: User deposited ".concat(depositAmount.toString()).concat(" FLOW"))
    
    // Step 4: Fund the lottery prize pool (simulating yield)
    // First fund the deployer account so it has tokens to fund the lottery
    let fundDeployerResult = Test.executeTransaction(
        Test.Transaction(
            code: fundAccountCode,
            authorizers: [serviceAccount.address],
            signers: [serviceAccount],
            arguments: [deployerAccount.address, prizeAmount + 1.0]
        )
    )
    Test.expect(fundDeployerResult, Test.beSucceeded())
    
    let fundLotteryCode = Test.readFile("../transactions/test/fund_lottery_pool.cdc")
    let fundLotteryResult = Test.executeTransaction(
        Test.Transaction(
            code: fundLotteryCode,
            authorizers: [deployerAccount.address],
            signers: [deployerAccount],
            arguments: [poolID, prizeAmount]
        )
    )
    if fundLotteryResult.error != nil {
        log("Fund lottery error: ".concat(fundLotteryResult.error!.message))
    }
    Test.expect(fundLotteryResult, Test.beSucceeded())
    log("Step 4: Funded lottery pool with ".concat(prizeAmount.toString()).concat(" FLOW"))
    
    // Verify lottery pool has funds
    let getDrawStatusScript = Test.readFile("../scripts/test/get_draw_status.cdc")
    let statusResult = Test.executeScript(getDrawStatusScript, [poolID])
    Test.expect(statusResult, Test.beSucceeded())
    let status = statusResult.returnValue! as! {String: AnyStruct}
    log("Lottery pool balance: ".concat((status["lotteryPoolBalance"]! as! UFix64).toString()))
    
    // Step 5: Advance time to allow draw (pool has 1 second interval)
    // Use Test.moveTime to advance the blockchain time
    Test.moveTime(by: 2.0)  // Move forward 2 seconds
    log("Step 5: Advanced time by 2 seconds")
    
    // Verify we can draw now
    let canDrawResult = Test.executeScript(getDrawStatusScript, [poolID])
    Test.expect(canDrawResult, Test.beSucceeded())
    let canDrawStatus = canDrawResult.returnValue! as! {String: AnyStruct}
    let canDrawNow = canDrawStatus["canDrawNow"]! as! Bool
    log("Can draw now: ".concat(canDrawNow ? "true" : "false"))
    Test.assert(canDrawNow, message: "Should be able to draw after time advancement")
    
    // Step 6: Start the draw
    let startDrawCode = Test.readFile("../transactions/test/start_draw.cdc")
    let startDrawResult = Test.executeTransaction(
        Test.Transaction(
            code: startDrawCode,
            authorizers: [drawUserAccount.address],
            signers: [drawUserAccount],
            arguments: [poolID]
        )
    )
    if startDrawResult.error != nil {
        log("Start draw error: ".concat(startDrawResult.error!.message))
    }
    Test.expect(startDrawResult, Test.beSucceeded())
    log("Step 6: Draw started")
    
    // Verify draw is in progress
    let inProgressResult = Test.executeScript(getDrawStatusScript, [poolID])
    Test.expect(inProgressResult, Test.beSucceeded())
    let inProgressStatus = inProgressResult.returnValue! as! {String: AnyStruct}
    let isDrawInProgress = inProgressStatus["isDrawInProgress"]! as! Bool
    Test.assert(isDrawInProgress, message: "Draw should be in progress")
    
    // Step 7: Advance blocks to get randomness (RandomConsumer needs block advancement)
    // Commit several empty blocks to ensure randomness is available
    Test.commitBlock()
    Test.commitBlock()
    Test.commitBlock()
    log("Step 7: Committed blocks for randomness")
    
    // Step 8: Complete the draw
    let completeDrawCode = Test.readFile("../transactions/test/complete_draw.cdc")
    let completeDrawResult = Test.executeTransaction(
        Test.Transaction(
            code: completeDrawCode,
            authorizers: [drawUserAccount.address],
            signers: [drawUserAccount],
            arguments: [poolID]
        )
    )
    if completeDrawResult.error != nil {
        log("Complete draw error: ".concat(completeDrawResult.error!.message))
    }
    Test.expect(completeDrawResult, Test.beSucceeded())
    log("Step 8: Draw completed")
    
    // Step 9: Verify the winner received the prize
    // Since there's only one participant, they should win
    let getUserPrizesScript = Test.readFile("../scripts/test/get_user_prizes.cdc")
    let prizesResult = Test.executeScript(getUserPrizesScript, [drawUserAccount.address, poolID])
    Test.expect(prizesResult, Test.beSucceeded())
    let prizes = prizesResult.returnValue! as! {String: UFix64}
    
    log("Final user deposits: ".concat(prizes["deposits"]!.toString()))
    log("Final user totalEarnedPrizes: ".concat(prizes["totalEarnedPrizes"]!.toString()))
    log("Final user savingsEarned: ".concat(prizes["savingsEarned"]!.toString()))
    log("Final user withdrawableBalance: ".concat(prizes["withdrawableBalance"]!.toString()))
    
    // The user should have won the prize (since they're the only participant)
    // Their totalEarnedPrizes should equal the prize amount (this is a cumulative stat)
    Test.assertEqual(prizeAmount, prizes["totalEarnedPrizes"]!)
    
    // Prize winnings are REINVESTED into deposits, so:
    // - deposits = original deposit + prize amount
    // - totalEarnedPrizes is just a stat tracking cumulative prizes won (not additional balance)
    let expectedDeposits = depositAmount + prizeAmount
    Test.assertEqual(expectedDeposits, prizes["deposits"]!)
    
    // Actual withdrawable balance = deposits + savingsEarned (prizes are already in deposits)
    let expectedWithdrawable = expectedDeposits + prizes["savingsEarned"]!
    log("Expected withdrawable balance: ".concat(expectedWithdrawable.toString()))
    
    log("Draw test completed successfully! Winner received ".concat(prizeAmount.toString()).concat(" FLOW prize (reinvested into deposits)"))
}

