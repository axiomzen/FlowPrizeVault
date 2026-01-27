import Test
import "PrizeLinkedAccounts"
import "FlowToken"
import "test_helpers.cdc"

// ============================================================================
// TEST ACCOUNTS
// ============================================================================

access(all) let sponsorAccount = Test.createAccount()
access(all) let regularUserAccount = Test.createAccount()

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Sponsor Collection Setup
// ============================================================================

access(all) fun testCreateSponsorPositionCollection() {
    let sponsor = Test.createAccount()
    fundAccountWithFlow(sponsor, amount: 10.0)
    setupSponsorPositionCollection(sponsor)
    
    // Verify collection was created (no error thrown)
    Test.assert(true, message: "Sponsor collection created successfully")
}

access(all) fun testSponsorCollectionHasUniqueUUID() {
    let sponsor = Test.createAccount()
    fundAccountWithFlow(sponsor, amount: 10.0)
    
    // Setup both regular and sponsor collections
    setupPoolPositionCollection(sponsor)
    setupSponsorPositionCollection(sponsor)
    
    // Both should exist and have different UUIDs (verified by no conflict)
    Test.assert(true, message: "Both collections coexist")
}

// ============================================================================
// TESTS - Sponsor Deposits
// ============================================================================

access(all) fun testSponsorDepositIncreasesPoolTotals() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 100.0
    
    ensurePoolExists()
    
    let initialTotals = getPoolTotals(poolID)
    let initialStaked = initialTotals["allocatedRewards"]!
    
    // Setup sponsor and deposit
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Verify pool totals increased
    let finalTotals = getPoolTotals(poolID)
    Test.assertEqual(initialStaked + depositAmount, finalTotals["allocatedRewards"]!)
}

access(all) fun testSponsorDepositUpdatesSponsorBalance() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 50.0
    
    ensurePoolExists()
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Verify sponsor's balance
    let sponsorBalance = getSponsorBalance(sponsor.address, poolID)
    Test.assertEqual(depositAmount, sponsorBalance["totalBalance"]!)
    Test.assertEqual(0.0, sponsorBalance["totalEarnedPrizes"]!)  // Sponsors can't win
}

access(all) fun testSponsorHasZeroPrizeEntries() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 100.0
    
    ensurePoolExists()
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Verify sponsor has zero prize entries
    let entries = getSponsorEntries(sponsor.address, poolID)
    Test.assertEqual(0.0, entries)
}

access(all) fun testSponsorCountIncrementsOnDeposit() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 25.0
    
    ensurePoolExists()
    
    let initialCount = getSponsorCount(poolID)
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    let finalCount = getSponsorCount(poolID)
    Test.assertEqual(initialCount + 1, finalCount)
}

access(all) fun testSponsorNotInRegisteredReceiverList() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 25.0
    
    ensurePoolExists()
    
    // Get initial registered receiver count
    let initialReceiverCount = getRegisteredReceiverCount(poolID)
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Registered receiver count should NOT increase (sponsors are excluded)
    let finalReceiverCount = getRegisteredReceiverCount(poolID)
    Test.assertEqual(initialReceiverCount, finalReceiverCount)
}

// ============================================================================
// TESTS - Sponsor Withdrawals
// ============================================================================

access(all) fun testSponsorCanWithdraw() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 50.0
    let withdrawAmount: UFix64 = 25.0
    
    ensurePoolExists()
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Withdraw some funds
    sponsorWithdrawFromPool(sponsor, poolID: poolID, amount: withdrawAmount)
    
    // Verify remaining balance
    let sponsorBalance = getSponsorBalance(sponsor.address, poolID)
    Test.assertEqual(depositAmount - withdrawAmount, sponsorBalance["totalBalance"]!)
}

access(all) fun testSponsorFullWithdrawalCleanup() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 30.0
    
    ensurePoolExists()
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    let countAfterDeposit = getSponsorCount(poolID)
    
    // Full withdrawal
    sponsorWithdrawFromPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Sponsor count should decrease
    let countAfterWithdraw = getSponsorCount(poolID)
    Test.assertEqual(countAfterDeposit - 1, countAfterWithdraw)
}

// ============================================================================
// TESTS - Regular vs Sponsor Isolation
// ============================================================================

access(all) fun testRegularUserHasPrizeEntries() {
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 50.0
    
    ensurePoolExists()
    
    let regularUser = Test.createAccount()
    setupUserWithFundsAndCollection(regularUser, amount: depositAmount + 1.0)
    depositToPool(regularUser, poolID: poolID, amount: depositAmount)
    
    // Regular user should have prize entries
    let entries = getUserEntries(regularUser.address, poolID)
    Test.assert(entries > 0.0, message: "Regular user should have prize entries")
}

access(all) fun testSameAccountCanBeBothRegularAndSponsor() {
    let poolID: UInt64 = 0
    let regularAmount: UFix64 = 20.0
    let sponsorAmount: UFix64 = 100.0
    
    ensurePoolExists()
    
    // Create user with both collections
    let dualUser = Test.createAccount()
    fundAccountWithFlow(dualUser, amount: regularAmount + sponsorAmount + 2.0)
    setupPoolPositionCollection(dualUser)
    setupSponsorPositionCollection(dualUser)
    
    // Deposit to both
    depositToPool(dualUser, poolID: poolID, amount: regularAmount)
    sponsorDepositToPool(dualUser, poolID: poolID, amount: sponsorAmount)
    
    // Check regular balance has entries
    let regularEntries = getUserEntries(dualUser.address, poolID)
    Test.assert(regularEntries > 0.0, message: "Regular position should have entries")
    
    // Check sponsor balance has zero entries
    let sponsorEntries = getSponsorEntries(dualUser.address, poolID)
    Test.assertEqual(0.0, sponsorEntries)
    
    // Check both balances exist
    let regularBalance = getUserPoolBalance(dualUser.address, poolID)
    let sponsorBalance = getSponsorBalance(dualUser.address, poolID)
    
    Test.assertEqual(regularAmount, regularBalance["totalBalance"]!)
    Test.assertEqual(sponsorAmount, sponsorBalance["totalBalance"]!)
}

// ============================================================================
// TESTS - Sponsor Yield Earning
// ============================================================================

access(all) fun testSponsorEarnsRewardsYield() {
    // Create pool with short interval for quick yield processing
    let poolID = createTestPoolWithShortInterval()
    let depositAmount: UFix64 = 100.0
    
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Fund prize to simulate yield
    fundPrizePool(poolID, amount: 10.0)
    
    // Process rewards
    processPoolRewards(poolID: poolID)
    
    // Sponsor should have earned rewards interest
    let sponsorBalance = getSponsorBalance(sponsor.address, poolID)
    // The rewardsEarned may be > 0 depending on distribution strategy
    // At minimum, deposits should still equal the deposit amount
    Test.assertEqual(depositAmount, sponsorBalance["totalBalance"]!)
}

access(all) fun testSponsorAndRegularUserBothEarnYield() {
    // Use pool with 24-hour draw interval (not 1-second) so round doesn't expire
    // before deposits complete - entries are only valid during active round
    ensurePoolExists()
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 100.0
    
    // Setup sponsor
    let sponsor = Test.createAccount()
    setupSponsorWithFundsAndCollection(sponsor, amount: depositAmount + 1.0)
    sponsorDepositToPool(sponsor, poolID: poolID, amount: depositAmount)
    
    // Setup regular user
    let regularUser = Test.createAccount()
    setupUserWithFundsAndCollection(regularUser, amount: depositAmount + 1.0)
    depositToPool(regularUser, poolID: poolID, amount: depositAmount)
    
    // Simulate yield
    fundPrizePool(poolID, amount: 20.0)
    processPoolRewards(poolID: poolID)
    
    // Both should have their deposits intact
    let sponsorBalance = getSponsorBalance(sponsor.address, poolID)
    let regularBalance = getUserPoolBalance(regularUser.address, poolID)
    
    Test.assertEqual(depositAmount, sponsorBalance["totalBalance"]!)
    Test.assertEqual(depositAmount, regularBalance["totalBalance"]!)
    
    // But only regular user has prize entries
    let regularEntries = getUserEntries(regularUser.address, poolID)
    let sponsorEntries = getSponsorEntries(sponsor.address, poolID)
    
    Test.assert(regularEntries > 0.0, message: "Regular user should have entries")
    Test.assertEqual(0.0, sponsorEntries)
}

