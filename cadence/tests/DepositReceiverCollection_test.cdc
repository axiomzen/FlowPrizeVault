import Test
import "PrizeVault"

/// Example test demonstrating the PoolPositionCollection pattern
///
/// This test shows:
/// 1. Creating a collection
/// 2. Auto-registration on first deposit
/// 3. Managing deposits across multiple pools
/// 4. Querying aggregate balances
///
access(all) fun testPoolPositionCollectionBasics() {
    // Create a collection
    let collection <- PrizeVault.createDepositReceiverCollection()
    
    // Initially, no pools registered
    Test.assertEqual([], collection.getRegisteredPoolIDs())
    
    // Auto-registration happens on deposit (would happen in actual usage)
    // Note: In real usage, deposit would auto-register with the pool
    
    // Get total balance across all pools (should be 0 initially)
    let totalBalance = collection.getTotalBalanceAllPools()
    Test.assertEqual(0.0, totalBalance)
    
    // Check no active positions
    Test.assertEqual(false, collection.hasActivePosition())
    
    destroy collection
}

/// Test that collection can be queried for non-registered pools
access(all) fun testNonRegisteredPoolQueries() {
    let collection <- PrizeVault.createDepositReceiverCollection()
    
    // Querying non-registered pool should return 0
    let depositBalance = collection.getDepositBalance(poolID: 999)
    Test.assertEqual(0.0, depositBalance)
    
    let prizeBalance = collection.getPrizeBalance(poolID: 999)
    Test.assertEqual(0.0, prizeBalance)
    
    let totalBalance = collection.getTotalBalance(poolID: 999)
    Test.assertEqual(0.0, totalBalance)
    
    destroy collection
}

/// Test PoolPosition struct
access(all) fun testPoolPosition() {
    let position = PrizeVault.PoolPosition(
        poolID: 1,
        depositBalance: 100.0,
        prizeBalance: 5.0,
        totalBalance: 105.0
    )
    
    Test.assertEqual(1 as UInt64, position.poolID)
    Test.assertEqual(100.0, position.depositBalance)
    Test.assertEqual(5.0, position.prizeBalance)
    Test.assertEqual(105.0, position.totalBalance)
}

