import Test
import "PrizeSavings"
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
    let poolIDs = PrizeSavings.getAllPoolIDs()
    Test.assertEqual(0, poolIDs.length)
}

access(all) fun testStoragePathsConfigured() {
    Test.assertEqual(/storage/PrizeSavingsCollection, PrizeSavings.PoolPositionCollectionStoragePath)
    Test.assertEqual(/public/PrizeSavingsCollection, PrizeSavings.PoolPositionCollectionPublicPath)
    Test.assertEqual(/storage/PrizeSavingsAdmin, PrizeSavings.AdminStoragePath)
}

access(all) fun testAdminResourceCreatedOnDeployment() {
    // The admin resource should exist at the deployer's storage
    let deployerAccount = getDeployerAccount()
    let adminExists = checkAdminExists(deployerAccount.address)
    Test.assert(adminExists, message: "Admin resource should exist after deployment")
}
