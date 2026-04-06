import Test
import "PrizeLinkedAccounts"
import "PLAPoolConnector"
import "test_helpers.cdc"

// ============================================================================
// TEST ACCOUNTS
// ============================================================================

access(all) let connectorUserAccount = Test.createAccount()

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Connector Creation
// ============================================================================

access(all) fun testCreateConnectorForPool() {
    ensurePoolExists()
    let poolID: UInt64 = 0

    setupUserWithFundsAndCollection(connectorUserAccount, amount: 10.0)

    let info = getConnectorInfo(connectorUserAccount.address, poolID)
    Test.assertEqual(poolID, info["poolID"]! as! UInt64)
}

// ============================================================================
// TESTS - Deposit via Connector
// ============================================================================

access(all) fun testConnectorDeposit() {
    ensurePoolExists()
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 5.0

    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)

    connectorDeposit(newUser, poolID: poolID, amount: depositAmount)

    let balance = getUserPoolBalance(newUser.address, poolID)
    Test.assertEqual(depositAmount, balance["totalBalance"]!)
}

// ============================================================================
// TESTS - Withdraw via Connector
// ============================================================================

access(all) fun testConnectorWithdraw() {
    ensurePoolExists()
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 5.0
    let withdrawAmount: UFix64 = 3.0

    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)

    connectorDeposit(newUser, poolID: poolID, amount: depositAmount)
    connectorWithdraw(newUser, poolID: poolID, amount: withdrawAmount)

    let balance = getUserPoolBalance(newUser.address, poolID)
    let remaining = depositAmount - withdrawAmount
    Test.assert(
        balance["totalBalance"]! >= remaining - 0.001 && balance["totalBalance"]! <= remaining + 0.001,
        message: "Expected ~".concat(remaining.toString()).concat(", got ").concat(balance["totalBalance"]!.toString())
    )
}

// ============================================================================
// TESTS - MinimumAvailable via Connector
// ============================================================================

access(all) fun testConnectorMinimumAvailable() {
    ensurePoolExists()
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 5.0

    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)

    connectorDeposit(newUser, poolID: poolID, amount: depositAmount)

    let available = getConnectorAvailable(newUser.address, poolID)
    Test.assertEqual(depositAmount, available)
}

// ============================================================================
// TESTS - Full withdrawal returns zero available
// ============================================================================

access(all) fun testConnectorFullWithdrawZeroAvailable() {
    ensurePoolExists()
    let poolID: UInt64 = 0
    let depositAmount: UFix64 = 5.0

    let newUser = Test.createAccount()
    setupUserWithFundsAndCollection(newUser, amount: depositAmount + 1.0)

    connectorDeposit(newUser, poolID: poolID, amount: depositAmount)
    connectorWithdraw(newUser, poolID: poolID, amount: depositAmount)

    let available = getConnectorAvailable(newUser.address, poolID)
    Test.assertEqual(0.0, available)
}
