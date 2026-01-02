import "PrizeSavings"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with CUSTOM draw interval
/// Uses MockYieldConnector for simplified testing
transaction(drawIntervalSeconds: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeSavings.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultCustom_".concat(currentPoolCount.toString()))!
        
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
        
        // Create distribution strategy (70% savings, 20% lottery, 10% treasury)
        let strategy = PrizeSavings.FixedPercentageStrategy(
            savings: 0.7,
            lottery: 0.2,
            treasury: 0.1
        )
        
        // Create prize distribution
        let prizeDistribution = PrizeSavings.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeSavings.PrizeDistribution}
        
        // Create pool config with CUSTOM draw interval
        let config = PrizeSavings.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: strategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )
        
        // Borrow admin resource and create pool
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with ").concat(drawIntervalSeconds.toString()).concat(" second draw interval"))
    }
}

