import Test
import "PrizeLinkedAccounts"
import "test_helpers.cdc"

// ============================================================================
// SETUP
// ============================================================================

access(all) fun setup() {
    deployAllDependencies()
}

// ============================================================================
// TESTS - Contract Deployment
// ============================================================================

access(all) fun testContractDeployed() {
    let poolIDs = PrizeLinkedAccounts.getAllPoolIDs()
    Test.assertEqual(0, poolIDs.length)
}

access(all) fun testStoragePathsConfigured() {
    Test.assertEqual(/storage/PrizeLinkedAccountsCollection, PrizeLinkedAccounts.PoolPositionCollectionStoragePath)
    Test.assertEqual(/public/PrizeLinkedAccountsCollection, PrizeLinkedAccounts.PoolPositionCollectionPublicPath)
    Test.assertEqual(/storage/PrizeLinkedAccountsAdmin, PrizeLinkedAccounts.AdminStoragePath)
}

access(all) fun testAdminResourceCreatedOnDeployment() {
    // The admin resource should exist at the deployer's storage
    let deployerAccount = getDeployerAccount()
    let adminExists = checkAdminExists(deployerAccount.address)
    Test.assert(adminExists, message: "Admin resource should exist after deployment")
}
