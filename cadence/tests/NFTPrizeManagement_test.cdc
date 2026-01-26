import Test
import "PrizeLinkedAccounts"
import "MockNFT"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
    deployMockNFT()

    // Setup deployer's MockNFT collection
    let deployerAccount = getDeployerAccount()
    setupMockNFTCollection(deployerAccount)
}

// ============================================================================
// TESTS - Admin NFT Operations
// ============================================================================

access(all) fun testAdminCanDepositNFTPrize() {
    let deployerAccount = getDeployerAccount()

    // Mint an NFT first - get both id and uuid
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Prize NFT #1", description: "Test NFT Prize")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with this NFT UUID in the distribution
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Verify NFT is in deployer's collection before deposit
    var nftIDs = getMockNFTIDs(deployerAccount.address)
    Test.assert(nftIDs.contains(nftID), message: "NFT should be in deployer's collection before deposit")

    // Deposit NFT as prize (using id for withdraw)
    depositNFTPrize(poolID, nftID: nftID)

    // Verify NFT is no longer in deployer's collection
    nftIDs = getMockNFTIDs(deployerAccount.address)
    Test.assert(!nftIDs.contains(nftID), message: "NFT should be removed from deployer's collection after deposit")

    // Verify NFT is in the pool's prize pool
    let nftCount = getNFTPrizeCount(poolID)
    Test.assertEqual(1, nftCount)
    let availableNFTIDs = getAvailableNFTPrizeIDs(poolID)
    Test.assert(availableNFTIDs.contains(nftUUID), message: "Pool should contain the deposited NFT by uuid")
}

access(all) fun testAdminCanDepositMultipleNFTPrizes() {
    let deployerAccount = getDeployerAccount()

    // Mint multiple NFTs - get both id and uuid for each
    let nft1 = mintMockNFTWithUUID(recipient: deployerAccount, name: "Prize NFT #1", description: "First NFT")
    let nft2 = mintMockNFTWithUUID(recipient: deployerAccount, name: "Prize NFT #2", description: "Second NFT")
    let nft3 = mintMockNFTWithUUID(recipient: deployerAccount, name: "Prize NFT #3", description: "Third NFT")

    // Create pool with all NFT UUIDs
    let poolID = createPoolWithNFTPrizes(nftIDs: [nft1["uuid"]!, nft2["uuid"]!, nft3["uuid"]!])

    // Deposit all NFTs (using ids for withdraw)
    depositNFTPrize(poolID, nftID: nft1["id"]!)
    depositNFTPrize(poolID, nftID: nft2["id"]!)
    depositNFTPrize(poolID, nftID: nft3["id"]!)

    // Verify all NFTs are in the pool
    let nftCount = getNFTPrizeCount(poolID)
    Test.assertEqual(3, nftCount)
}

access(all) fun testAdminCanWithdrawUnassignedNFTPrize() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Prize NFT", description: "Test NFT")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with this NFT UUID
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Deposit the NFT
    depositNFTPrize(poolID, nftID: nftID)

    // Verify NFT is in pool
    var nftPrizeCount = getNFTPrizeCount(poolID)
    Test.assertEqual(1, nftPrizeCount)

    // Withdraw the NFT (using uuid since pool stores by uuid)
    withdrawNFTPrize(poolID, nftID: nftUUID)

    // Verify NFT is no longer in pool
    nftPrizeCount = getNFTPrizeCount(poolID)
    Test.assertEqual(0, nftPrizeCount)

    // Verify NFT is back in deployer's collection
    let nftIDs = getMockNFTIDs(deployerAccount.address)
    Test.assert(nftIDs.contains(nftID), message: "NFT should be back in deployer's collection")
}

access(all) fun testWithdrawNonExistentNFTPrizeFails() {
    // Create pool without NFT IDs
    let poolID = createTestPoolWithShortInterval()

    // Try to withdraw an NFT that doesn't exist
    let success = withdrawNFTPrizeExpectFailure(poolID, nftID: 999999)
    Test.assertEqual(false, success)
}

// ============================================================================
// TESTS - NFT Prize in Draws
// ============================================================================

access(all) fun testNFTPrizeAwardedToWinner() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT first
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Winner Prize NFT", description: "Draw prize")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with this NFT UUID in the distribution
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Deposit the NFT to the pool
    depositNFTPrize(poolID, nftID: nftID)

    // Setup single participant (guaranteed winner)
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund token prize and execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify winner has pending NFT claim
    let pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(1, pendingCount)

    // Verify NFT is no longer in available prizes
    let nftCount = getNFTPrizeCount(poolID)
    Test.assertEqual(0, nftCount)
}

access(all) fun testNFTPrizeWithTokenPrizeCombined() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Combo Prize NFT", description: "NFT + Token")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with NFT UUID
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Deposit NFT
    depositNFTPrize(poolID, nftID: nftID)

    // Setup single participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Fund token prize and execute draw
    let tokenPrizeAmount = DEFAULT_PRIZE_AMOUNT
    fundPrizePool(poolID, amount: tokenPrizeAmount)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify winner received both token prize and NFT
    let prizes = getUserPrizes(participant.address, poolID)
    Test.assertEqual(tokenPrizeAmount, prizes["totalEarnedPrizes"]!)

    let pendingNFTCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(1, pendingNFTCount)
}

// ============================================================================
// TESTS - User NFT Claiming
// ============================================================================

access(all) fun testWinnerCanClaimPendingNFT() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Claimable NFT", description: "For claiming test")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with NFT UUID
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])

    // Deposit NFT
    depositNFTPrize(poolID, nftID: nftID)

    // Setup single participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify pending NFT before claim
    var pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(1, pendingCount)

    // Claim the NFT
    claimPendingNFT(participant, poolID: poolID, nftIndex: 0)

    // Verify NFT is now in user's collection
    let userNFTIDs = getMockNFTIDs(participant.address)
    Test.assert(userNFTIDs.length == 1, message: "User should have 1 NFT in collection")

    // Verify pending count is now 0
    pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(0, pendingCount)
}

access(all) fun testWinnerCanClaimMultiplePendingNFTs() {
    let deployerAccount = getDeployerAccount()

    // Mint 2 NFTs upfront
    let nft1 = mintMockNFTWithUUID(recipient: deployerAccount, name: "NFT Prize #1", description: "First prize")
    let nft2 = mintMockNFTWithUUID(recipient: deployerAccount, name: "NFT Prize #2", description: "Second prize")

    // Create pool with BOTH NFT UUIDs in the distribution
    // Both NFTs will be awarded to the single winner
    let poolID = createPoolWithNFTPrizes(nftIDs: [nft1["uuid"]!, nft2["uuid"]!])

    // Deposit both NFTs
    depositNFTPrize(poolID, nftID: nft1["id"]!)
    depositNFTPrize(poolID, nftID: nft2["id"]!)

    // Setup single participant (will win all NFTs)
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify 2 pending NFTs
    var pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(2, pendingCount)

    // Claim first NFT (index 0)
    claimPendingNFT(participant, poolID: poolID, nftIndex: 0)

    // Verify 1 pending NFT remaining
    pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(1, pendingCount)

    // Claim second NFT (now at index 0)
    claimPendingNFT(participant, poolID: poolID, nftIndex: 0)

    // Verify no pending NFTs
    pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(0, pendingCount)

    // Verify user has 2 NFTs
    let userNFTIDs = getMockNFTIDs(participant.address)
    Test.assertEqual(2, userNFTIDs.length)
}

access(all) fun testClaimNFTWithInvalidIndexFails() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Single NFT", description: "Only one")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool and deposit NFT
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])
    depositNFTPrize(poolID, nftID: nftID)

    // Setup single participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Try to claim with invalid index
    let success = claimPendingNFTExpectFailure(participant, poolID: poolID, nftIndex: 99)
    Test.assertEqual(false, success)
}

access(all) fun testNonWinnerCannotClaimNFT() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "NFT Prize", description: "Test")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool and deposit NFT
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])
    depositNFTPrize(poolID, nftID: nftID)

    // Setup participant who will win
    let winner = Test.createAccount()
    setupUserWithFundsAndCollection(winner, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(winner)
    depositToPool(winner, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Setup another user who didn't participate
    let nonWinner = Test.createAccount()
    setupUserWithFundsAndCollection(nonWinner, amount: 10.0)
    setupMockNFTCollection(nonWinner)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Verify winner has pending NFT
    let winnerPending = getPendingNFTCount(winner.address, poolID)
    Test.assertEqual(1, winnerPending)

    // Verify non-winner has no pending NFTs
    let nonWinnerPending = getPendingNFTCount(nonWinner.address, poolID)
    Test.assertEqual(0, nonWinnerPending)
}

// ============================================================================
// TESTS - NFT State Queries
// ============================================================================

access(all) fun testGetPendingNFTCountReturnsCorrectValue() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "NFT #1", description: "First")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool with NFT
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])
    depositNFTPrize(poolID, nftID: nftID)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Initial count should be 0
    var pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(0, pendingCount)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Pending count should be 1
    pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(1, pendingCount)

    // Claim the NFT
    claimPendingNFT(participant, poolID: poolID, nftIndex: 0)

    // Pending count should be 0
    pendingCount = getPendingNFTCount(participant.address, poolID)
    Test.assertEqual(0, pendingCount)
}

access(all) fun testGetPendingNFTIDsReturnsCorrectIDs() {
    let deployerAccount = getDeployerAccount()

    // Mint NFT
    let nftData = mintMockNFTWithUUID(recipient: deployerAccount, name: "Tracked NFT", description: "Track this")
    let nftID = nftData["id"]!
    let nftUUID = nftData["uuid"]!

    // Create pool and deposit NFT
    let poolID = createPoolWithNFTPrizes(nftIDs: [nftUUID])
    depositNFTPrize(poolID, nftID: nftID)

    // Setup participant
    let participant = Test.createAccount()
    setupUserWithFundsAndCollection(participant, amount: DEFAULT_DEPOSIT_AMOUNT + 1.0)
    setupMockNFTCollection(participant)
    depositToPool(participant, poolID: poolID, amount: DEFAULT_DEPOSIT_AMOUNT)

    // Execute draw
    fundPrizePool(poolID, amount: DEFAULT_PRIZE_AMOUNT)
    Test.moveTime(by: 61.0)
    executeFullDraw(deployerAccount, poolID: poolID)

    // Get pending NFT IDs
    let pendingIDs = getPendingNFTIDs(participant.address, poolID)
    Test.assertEqual(1, pendingIDs.length)
    // The pending ID should match the deposited NFT's UUID
    Test.assertEqual(nftUUID, pendingIDs[0])
}
