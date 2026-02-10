import Test
import "test_helpers.cdc"

// ============================================================================
// DEPOSIT SLIPPAGE ACCOUNTING TEST SUITE
// ============================================================================
//
// Verifies that the slippage reconciliation logic correctly accounts for
// deposit fees charged by the yield connector. Uses a mock connector that
// charges a configurable fee (in basis points) on every deposit.
//
// Key invariant tested after every deposit/withdrawal/sync:
//   allocatedRewards + allocatedPrizeYield + allocatedProtocolFee == yieldVaultBalance
//
// ============================================================================

// ============================================================================
// CONSTANTS
// ============================================================================

access(all) let TOLERANCE: UFix64 = 0.00000001  // 1 unit of UFix64 precision

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// HELPER: Assert accounting invariant
// ============================================================================

access(all) fun assertAccountingInvariant(_ poolID: UInt64, _ poolIndex: Int, context: String) {
    let rewardsInfo = getPoolRewardsInfo(poolID)
    let vaultBalance = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)

    let allocatedRewards = rewardsInfo["userPoolBalance"]!
    let allocatedPrizeYield = rewardsInfo["allocatedPrizeYield"]!
    let allocatedProtocolFee = rewardsInfo["allocatedProtocolFee"]!
    let totalAllocated = allocatedRewards + allocatedPrizeYield + allocatedProtocolFee
    let sharePrice = rewardsInfo["sharePrice"] ?? 0.0
    let totalShares = rewardsInfo["totalShares"] ?? 0.0
    let totalAssets = rewardsInfo["totalAssets"] ?? 0.0

    log("─── Invariant Check: ".concat(context).concat(" ───"))
    log("  Yield Vault Balance:    ".concat(vaultBalance.toString()))
    log("  allocatedRewards:       ".concat(allocatedRewards.toString()))
    log("  allocatedPrizeYield:    ".concat(allocatedPrizeYield.toString()))
    log("  allocatedProtocolFee:   ".concat(allocatedProtocolFee.toString()))
    log("  Total Allocated:        ".concat(totalAllocated.toString()))
    log("  Difference:             ".concat(absDifference(totalAllocated, vaultBalance).toString()))
    log("  Share Price:            ".concat(sharePrice.toString()))
    log("  Total Shares:           ".concat(totalShares.toString()))
    log("  Total Assets:           ".concat(totalAssets.toString()))
    log("  MATCH: ".concat(isWithinTolerance(totalAllocated, vaultBalance, TOLERANCE) ? "YES ✓" : "NO ✗"))

    Test.assert(
        isWithinTolerance(totalAllocated, vaultBalance, TOLERANCE),
        message: context.concat(" - Accounting mismatch: allocated=").concat(totalAllocated.toString())
            .concat(" vault=").concat(vaultBalance.toString())
            .concat(" (rewards=").concat(allocatedRewards.toString())
            .concat(" prize=").concat(allocatedPrizeYield.toString())
            .concat(" protocol=").concat(allocatedProtocolFee.toString()).concat(")")
    )
}

// ============================================================================
// TEST: Single deposit with slippage accounting match
// ============================================================================

access(all) fun testSingleDepositWithSlippageAccountingMatch() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Single Deposit with 2% Slippage                     ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    // Create pool with 2% slippage connector (70/20/10 distribution)
    log("\n▸ Step 1: Creating pool with SlippageVaultConnector (2% fee, 70/20/10 split)")
    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    let poolIndex = Int(poolID)
    log("  Pool created: ID=".concat(poolID.toString()).concat(", index=").concat(poolIndex.toString()))

    // Create user and deposit 100 FLOW
    log("\n▸ Step 2: User deposits 100.0 FLOW")
    log("  Expected: connector takes 2% fee → 98.0 FLOW lands in yield vault")
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Assert yield vault balance = 98.0 FLOW (100 - 2%)
    let vaultBalance = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("\n▸ Step 3: Checking yield vault balance")
    log("  Actual vault balance: ".concat(vaultBalance.toString()))
    log("  Expected:             98.0")
    Test.assert(
        isWithinTolerance(vaultBalance, 98.0, TOLERANCE),
        message: "Vault balance should be 98.0 after 2% fee, got: ".concat(vaultBalance.toString())
    )

    // Assert allocatedRewards matches actual received (98.0), not nominal (100.0)
    let rewardsInfo = getPoolRewardsInfo(poolID)
    let allocatedRewards = rewardsInfo["userPoolBalance"]!
    log("\n▸ Step 4: Checking allocatedRewards (should match vault, NOT nominal deposit)")
    log("  allocatedRewards: ".concat(allocatedRewards.toString()))
    log("  Expected:         98.0 (actual received, not 100.0 nominal)")
    Test.assert(
        isWithinTolerance(allocatedRewards, 98.0, TOLERANCE),
        message: "allocatedRewards should be 98.0 (actual received), got: ".concat(allocatedRewards.toString())
    )

    // Assert the key invariant
    log("\n▸ Step 5: Verifying accounting invariant")
    assertAccountingInvariant(poolID, poolIndex, context: "Single deposit")
    log("")
}

// ============================================================================
// TEST: Multiple deposits with slippage accounting match
// ============================================================================

access(all) fun testMultipleDepositsWithSlippageAccountingMatch() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Multiple Deposits with 2% Slippage                  ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    let poolIndex = Int(poolID)
    log("  Pool created: ID=".concat(poolID.toString()))

    // User A deposits 100 FLOW → vault should have 98.0
    log("\n▸ User A deposits 100.0 FLOW")
    let userA = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: 200.0)
    depositToPool(userA, poolID: poolID, amount: 100.0)

    let balanceAfterA = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterA.toString()).concat(" (expected 98.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterA, 98.0, TOLERANCE),
        message: "After user A: vault should be 98.0, got: ".concat(balanceAfterA.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After user A deposit")

    // User B deposits 50 FLOW → vault should have 98.0 + 49.0 = 147.0
    log("\n▸ User B deposits 50.0 FLOW")
    log("  Expected vault: 98.0 + (50.0 × 0.98) = 147.0")
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userB, amount: 200.0)
    depositToPool(userB, poolID: poolID, amount: 50.0)

    let balanceAfterB = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterB.toString()).concat(" (expected 147.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterB, 147.0, TOLERANCE),
        message: "After user B: vault should be 147.0, got: ".concat(balanceAfterB.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After user B deposit")

    // User C deposits 200 FLOW → vault should have 147.0 + 196.0 = 343.0
    log("\n▸ User C deposits 200.0 FLOW")
    log("  Expected vault: 147.0 + (200.0 × 0.98) = 343.0")
    let userC = Test.createAccount()
    setupUserWithFundsAndCollection(userC, amount: 300.0)
    depositToPool(userC, poolID: poolID, amount: 200.0)

    let balanceAfterC = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterC.toString()).concat(" (expected 343.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterC, 343.0, TOLERANCE),
        message: "After user C: vault should be 343.0, got: ".concat(balanceAfterC.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After user C deposit")
    log("")
}

// ============================================================================
// TEST: Slippage does not affect share price fairness
// ============================================================================

access(all) fun testSlippageDoesNotAffectSharePriceFairness() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Share Price Fairness with Slippage                   ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    log("  Pool created: ID=".concat(poolID.toString()))

    // User A deposits 100 FLOW → gets shares based on 98 actual
    log("\n▸ User A deposits 100.0 FLOW (98.0 after 2% fee)")
    let userA = Test.createAccount()
    setupUserWithFundsAndCollection(userA, amount: 200.0)
    depositToPool(userA, poolID: poolID, amount: 100.0)

    let sharesA = getUserShareDetails(userA.address, poolID)
    let userAShares = sharesA["shares"]!
    log("  User A shares: ".concat(userAShares.toString()))

    // User B deposits 100 FLOW → gets shares based on 98 actual
    log("\n▸ User B deposits 100.0 FLOW (98.0 after 2% fee)")
    let userB = Test.createAccount()
    setupUserWithFundsAndCollection(userB, amount: 200.0)
    depositToPool(userB, poolID: poolID, amount: 100.0)

    let sharesB = getUserShareDetails(userB.address, poolID)
    let userBShares = sharesB["shares"]!
    log("  User B shares: ".concat(userBShares.toString()))

    // Both users should have equal shares (same effective deposit)
    log("\n▸ Fairness check: do equal deposits get equal shares?")
    log("  User A shares: ".concat(userAShares.toString()))
    log("  User B shares: ".concat(userBShares.toString()))
    log("  Difference:    ".concat(absDifference(userAShares, userBShares).toString()))
    Test.assert(
        isWithinTolerance(userAShares, userBShares, 0.00001),
        message: "Users should have equal shares: A=".concat(userAShares.toString())
            .concat(" B=").concat(userBShares.toString())
    )

    // Share price should remain ~1.0 (no dilution from slippage)
    let rewardsInfo = getPoolRewardsInfo(poolID)
    let sharePrice = rewardsInfo["sharePrice"]!
    log("\n▸ Share price check (should be ~1.0, no dilution)")
    log("  Share price: ".concat(sharePrice.toString()))
    Test.assert(
        isWithinTolerance(sharePrice, 1.0, 0.0001),
        message: "Share price should be ~1.0, got: ".concat(sharePrice.toString())
    )
    log("")
}

// ============================================================================
// TEST: Slippage with yield accrual
// ============================================================================

access(all) fun testSlippageWithYieldAccrual() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Slippage + Yield Accrual + Second Deposit            ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    let poolIndex = Int(poolID)
    log("  Pool created: ID=".concat(poolID.toString()))

    // Deposit 100 FLOW → vault has 98
    log("\n▸ Step 1: User deposits 100.0 FLOW")
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 300.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    let balanceAfterDeposit = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterDeposit.toString()).concat(" (expected 98.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterDeposit, 98.0, TOLERANCE),
        message: "Post-deposit vault should be 98.0, got: ".concat(balanceAfterDeposit.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After initial deposit")

    // Simulate yield appreciation of 10 FLOW → vault has 108
    log("\n▸ Step 2: Simulate yield appreciation of 10.0 FLOW")
    log("  Expected vault: 98.0 + 10.0 = 108.0")
    let deployerAccount = getDeployerAccount()
    fundAccountWithFlow(deployerAccount, amount: 15.0)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_SLIPPAGE)

    let balanceBeforeSync = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance (pre-sync):  ".concat(balanceBeforeSync.toString()))

    // Trigger sync to distribute yield
    log("\n▸ Step 3: Trigger syncWithYieldSource (distributes yield via 70/20/10)")
    triggerSyncWithYieldSource(poolID: poolID)

    // Verify vault balance is 108 and invariant holds
    let balanceAfterYield = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance (post-sync): ".concat(balanceAfterYield.toString()).concat(" (expected 108.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterYield, 108.0, TOLERANCE),
        message: "Post-yield vault should be 108.0, got: ".concat(balanceAfterYield.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After yield accrual")

    // Second deposit of 50 FLOW → vault has 108 + 49 = 157
    log("\n▸ Step 4: User deposits another 50.0 FLOW")
    log("  Expected vault: 108.0 + (50.0 × 0.98) = 157.0")
    depositToPool(user, poolID: poolID, amount: 50.0)

    let balanceAfterSecondDeposit = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterSecondDeposit.toString()).concat(" (expected 157.0)"))
    Test.assert(
        isWithinTolerance(balanceAfterSecondDeposit, 157.0, TOLERANCE),
        message: "After second deposit vault should be 157.0, got: ".concat(balanceAfterSecondDeposit.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After second deposit with yield")
    log("")
}

// ============================================================================
// TEST: Slippage with withdrawals
// ============================================================================

access(all) fun testSlippageWithWithdrawals() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Slippage + Withdrawal                                ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    let poolIndex = Int(poolID)
    log("  Pool created: ID=".concat(poolID.toString()))

    // Deposit 100 FLOW → vault has 98, allocatedRewards = 98
    log("\n▸ Step 1: User deposits 100.0 FLOW (98.0 after 2% fee)")
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 200.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    let balanceAfterDeposit = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterDeposit.toString()))

    let sharesBeforeWithdraw = getUserShareDetails(user.address, poolID)
    log("  User shares:   ".concat((sharesBeforeWithdraw["shares"]!).toString()))
    assertAccountingInvariant(poolID, poolIndex, context: "After deposit, before withdrawal")

    // Withdraw 50 FLOW → vault should decrease, accounting should match
    log("\n▸ Step 2: User withdraws 50.0 FLOW")
    log("  Expected vault: 98.0 - 50.0 = 48.0")
    withdrawFromPool(user, poolID: poolID, amount: 50.0)

    // Verify invariant after withdrawal
    let balanceAfterWithdraw = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("  Vault balance: ".concat(balanceAfterWithdraw.toString()).concat(" (expected ~48.0)"))

    let sharesAfterWithdraw = getUserShareDetails(user.address, poolID)
    log("  User shares:   ".concat((sharesAfterWithdraw["shares"]!).toString()))
    Test.assert(
        isWithinTolerance(balanceAfterWithdraw, 48.0, TOLERANCE),
        message: "After withdrawal vault should be ~48.0, got: ".concat(balanceAfterWithdraw.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After withdrawal")
    log("")
}

// ============================================================================
// TEST: Slippage protection rejects excessive slippage
// ============================================================================

access(all) fun testSlippageProtectionRejectsExcessiveSlippage() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Slippage Protection (max tolerance enforcement)      ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    log("  Pool created: ID=".concat(poolID.toString()).concat(" (2% deposit fee)"))

    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 500.0)

    // Attempt deposit with maxSlippageBps = 100 (1% max tolerance)
    // Should FAIL because actual slippage (2%) exceeds max tolerance (1%)
    log("\n▸ Step 1: Attempt deposit with maxSlippageBps=100 (1% tolerance)")
    log("  Actual fee is 2% → should REJECT (2% > 1%)")
    let shouldFail = depositToPoolWithSlippageExpectFailure(
        user, poolID: poolID, amount: 100.0, maxSlippageBps: 100
    )
    log("  Transaction succeeded: ".concat(shouldFail ? "true (BAD)" : "false (GOOD - correctly rejected)"))
    Test.assertEqual(false, shouldFail)

    // Attempt deposit with maxSlippageBps = 200 (2% tolerance, exactly matching fee)
    // Should SUCCEED
    log("\n▸ Step 2: Attempt deposit with maxSlippageBps=200 (2% tolerance)")
    log("  Actual fee is 2% → should ACCEPT (2% <= 2%)")
    depositToPoolWithSlippage(user, poolID: poolID, amount: 100.0, maxSlippageBps: 200)
    log("  Transaction succeeded: true (GOOD)")

    // Verify the deposit went through correctly
    let poolIndex = Int(poolID)
    let vaultBalance = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    log("\n▸ Step 3: Verify deposit landed correctly")
    log("  Vault balance: ".concat(vaultBalance.toString()).concat(" (expected 98.0)"))
    Test.assert(
        isWithinTolerance(vaultBalance, 98.0, TOLERANCE),
        message: "Vault should have 98.0 after successful 2% slippage deposit, got: ".concat(vaultBalance.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "After slippage-protected deposit")
    log("")
}

// ============================================================================
// TEST: Yield distribution buckets change correctly through slippage + yield
// ============================================================================

access(all) fun testSlippageWithYieldDistributionBuckets() {
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║  TEST: Yield Distribution Buckets (70/20/10 split)          ║")
    log("╚══════════════════════════════════════════════════════════════╝")

    // Step 1: Create pool with 2% slippage connector, 70/20/10 distribution
    log("\n▸ Step 1: Creating pool with SlippageVaultConnector (2% fee, 70/20/10 split)")
    let poolID = createPoolWithSlippageConnector(
        rewards: 0.7, prize: 0.2, protocolFee: 0.1, depositFeeBps: 200
    )
    let poolIndex = Int(poolID)
    log("  Pool created: ID=".concat(poolID.toString()).concat(", index=").concat(poolIndex.toString()))

    // Step 2: User deposits 100 FLOW → vault has 98 after 2% fee
    log("\n▸ Step 2: User deposits 100.0 FLOW (98.0 after 2% fee)")
    let user = Test.createAccount()
    setupUserWithFundsAndCollection(user, amount: 500.0)
    depositToPool(user, poolID: poolID, amount: 100.0)

    // Step 3: Log & assert pre-yield state — all yield buckets should be 0
    log("\n▸ Step 3: Verify pre-yield state (buckets should be zero)")
    let preYieldInfo = getPoolRewardsInfo(poolID)
    let preRewards = preYieldInfo["userPoolBalance"]!
    let prePrize = preYieldInfo["allocatedPrizeYield"]!
    let preProtocol = preYieldInfo["allocatedProtocolFee"]!
    let preSharePrice = preYieldInfo["sharePrice"] ?? 0.0
    let preVault = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)

    log("  allocatedRewards:     ".concat(preRewards.toString()).concat(" (expected 98.0)"))
    log("  allocatedPrizeYield:  ".concat(prePrize.toString()).concat(" (expected 0.0)"))
    log("  allocatedProtocolFee: ".concat(preProtocol.toString()).concat(" (expected 0.0)"))
    log("  sharePrice:           ".concat(preSharePrice.toString()).concat(" (expected ~1.0)"))
    log("  vaultBalance:         ".concat(preVault.toString()).concat(" (expected 98.0)"))

    Test.assert(
        isWithinTolerance(preRewards, 98.0, TOLERANCE),
        message: "Pre-yield allocatedRewards should be 98.0, got: ".concat(preRewards.toString())
    )
    Test.assert(
        isWithinTolerance(prePrize, 0.0, TOLERANCE),
        message: "Pre-yield allocatedPrizeYield should be 0.0, got: ".concat(prePrize.toString())
    )
    Test.assert(
        isWithinTolerance(preProtocol, 0.0, TOLERANCE),
        message: "Pre-yield allocatedProtocolFee should be 0.0, got: ".concat(preProtocol.toString())
    )
    Test.assert(
        isWithinTolerance(preSharePrice, 1.0, 0.0001),
        message: "Pre-yield sharePrice should be ~1.0, got: ".concat(preSharePrice.toString())
    )
    assertAccountingInvariant(poolID, poolIndex, context: "Pre-yield state")

    // Step 4: Simulate 10 FLOW yield appreciation → vault = 108
    log("\n▸ Step 4: Simulate 10.0 FLOW yield appreciation")
    log("  Expected vault: 98.0 + 10.0 = 108.0")
    let deployerAccount = getDeployerAccount()
    fundAccountWithFlow(deployerAccount, amount: 15.0)
    simulateYieldAppreciation(poolIndex: poolIndex, amount: 10.0, vaultPrefix: VAULT_PREFIX_SLIPPAGE)

    // Step 5: Log pre-deposit state — vault is 108 but allocations still sum to 98 (stale)
    let staleVault = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)
    let staleInfo = getPoolRewardsInfo(poolID)
    let staleTotal = staleInfo["userPoolBalance"]! + staleInfo["allocatedPrizeYield"]! + staleInfo["allocatedProtocolFee"]!
    log("\n▸ Step 5: Pre-deposit state (yield unrecognized, allocations stale)")
    log("  Vault balance:    ".concat(staleVault.toString()).concat(" (108.0 — yield added)"))
    log("  Total allocated:  ".concat(staleTotal.toString()).concat(" (98.0 — stale, no sync yet)"))
    log("  Unrecognized yield: ".concat(absDifference(staleVault, staleTotal).toString()))

    // Step 6: User deposits another 50 FLOW — this triggers sync internally
    log("\n▸ Step 6: User deposits 50.0 FLOW (triggers sync → distributes 10.0 yield via 70/20/10)")
    log("  Expected: sync distributes yield, then 50 FLOW deposit lands (49.0 after 2% fee)")
    depositToPool(user, poolID: poolID, amount: 50.0)

    // Step 7: Log & assert post-second-deposit state
    log("\n▸ Step 7: Verify post-second-deposit state (buckets should reflect yield distribution)")
    let postInfo = getPoolRewardsInfo(poolID)
    let postRewards = postInfo["userPoolBalance"]!
    let postPrize = postInfo["allocatedPrizeYield"]!
    let postProtocol = postInfo["allocatedProtocolFee"]!
    let postSharePrice = postInfo["sharePrice"] ?? 0.0
    let postTotalShares = postInfo["totalShares"] ?? 0.0
    let postTotalAssets = postInfo["totalAssets"] ?? 0.0
    let postVault = getYieldVaultBalance(poolIndex: poolIndex, vaultPrefix: VAULT_PREFIX_SLIPPAGE)

    log("  allocatedRewards:     ".concat(postRewards.toString()))
    log("  allocatedPrizeYield:  ".concat(postPrize.toString()))
    log("  allocatedProtocolFee: ".concat(postProtocol.toString()))
    log("  sharePrice:           ".concat(postSharePrice.toString()))
    log("  totalShares:          ".concat(postTotalShares.toString()))
    log("  totalAssets:          ".concat(postTotalAssets.toString()))
    log("  vaultBalance:         ".concat(postVault.toString()))

    // allocatedPrizeYield should be ~2.0 (20% of 10 FLOW yield)
    log("\n  ── Bucket assertions ──")
    log("  allocatedPrizeYield: ".concat(postPrize.toString()).concat(" (expected ~2.0 = 20% of 10)"))
    Test.assert(
        isWithinTolerance(postPrize, 2.0, 0.001),
        message: "allocatedPrizeYield should be ~2.0 (20% of 10 yield), got: ".concat(postPrize.toString())
    )

    // allocatedProtocolFee should be ~1.0 (10% of 10 FLOW yield)
    log("  allocatedProtocolFee: ".concat(postProtocol.toString()).concat(" (expected ~1.0 = 10% of 10)"))
    Test.assert(
        isWithinTolerance(postProtocol, 1.0, 0.001),
        message: "allocatedProtocolFee should be ~1.0 (10% of 10 yield), got: ".concat(postProtocol.toString())
    )

    // allocatedRewards should be ~154.0 (98 original + 7.0 yield rewards + 49.0 second deposit)
    log("  allocatedRewards: ".concat(postRewards.toString()).concat(" (expected ~154.0 = 98 + 7 + 49)"))
    Test.assert(
        isWithinTolerance(postRewards, 154.0, 0.01),
        message: "allocatedRewards should be ~154.0, got: ".concat(postRewards.toString())
    )

    // sharePrice should be > 1.0 (yield increased share value before second deposit)
    log("  sharePrice: ".concat(postSharePrice.toString()).concat(" (expected > 1.0)"))
    Test.assert(
        postSharePrice > 1.0,
        message: "sharePrice should be > 1.0 after yield, got: ".concat(postSharePrice.toString())
    )

    // Vault balance should be ~157.0 (108 + 49)
    log("  vaultBalance: ".concat(postVault.toString()).concat(" (expected ~157.0 = 108 + 49)"))
    Test.assert(
        isWithinTolerance(postVault, 157.0, 0.01),
        message: "Vault balance should be ~157.0, got: ".concat(postVault.toString())
    )

    // Invariant: total allocated == vault balance
    assertAccountingInvariant(poolID, poolIndex, context: "After second deposit with yield distribution")

    // Step 8: Log the deltas for each bucket
    let deltaRewards = postRewards - preRewards
    let deltaPrize = postPrize - prePrize
    let deltaProtocol = postProtocol - preProtocol
    log("\n▸ Step 8: Bucket deltas (post - pre)")
    log("  Δ allocatedRewards:     ".concat(deltaRewards.toString()).concat(" (expected ~56.0 = 7 yield + 49 deposit)"))
    log("  Δ allocatedPrizeYield:  ".concat(deltaPrize.toString()).concat(" (expected ~2.0 = 20% of 10)"))
    log("  Δ allocatedProtocolFee: ".concat(deltaProtocol.toString()).concat(" (expected ~1.0 = 10% of 10)"))
    log("  Total delta:            ".concat((deltaRewards + deltaPrize + deltaProtocol).toString()))
    log("  Vault delta:            ".concat(absDifference(postVault, preVault).toString()))
    log("")
}
