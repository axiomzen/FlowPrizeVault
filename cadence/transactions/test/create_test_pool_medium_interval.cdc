import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with MEDIUM draw interval (60 seconds) for testing entries
/// Uses MockYieldConnector for simplified testing
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultMedium_".concat(currentPoolCount.toString()))!
        
        // Create a test vault to use as yield source
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        // Create capabilities for the connector
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&FlowToken.Vault>(vaultPath)
        
        // Create mock connector using MockYieldConnector
        let mockConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        // Create distribution strategy (70% rewards, 20% prize, 10% protocol)
        let strategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: 0.7,
            prize: 0.2,
            protocolFee: 0.1
        )
        
        // Create prize distribution
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeLinkedAccounts.PrizeDistribution}
        
        // Create pool config with MEDIUM draw interval (60 seconds for testing entries)
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 60.0,  // 60 seconds for entry testing
            distributionStrategy: strategy,
            prizeDistribution: prizeDistribution
        )
        
        // Borrow admin resource and create pool
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with 60 second draw interval"))
    }
}
