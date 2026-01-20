import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with LIMITED capacity connector
/// Used for testing deposit capacity overflow protection
transaction(capacityLimit: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultLimited_".concat(currentPoolCount.toString()))!
        
        // Create a test vault to use as yield source
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        // Create capabilities for the connector
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&FlowToken.Vault>(vaultPath)
        
        // Create LIMITED capacity connector - this will only accept up to capacityLimit
        let limitedConnector = MockYieldConnector.createLimitedCapacityConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>(),
            capacityLimit: capacityLimit
        )
        
        // Create distribution strategy (70% savings, 20% lottery, 10% treasury)
        let strategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: 0.7,
            prize: 0.2,
            treasury: 0.1
        )
        
        // Create prize distribution
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeLinkedAccounts.PrizeDistribution}
        
        // Create pool config with limited connector
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: limitedConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 86400.0, // 24 hours
            distributionStrategy: strategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )
        
        // Borrow admin resource and create pool
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )
        
        log("Created limited capacity pool with ID: ".concat(poolID.toString()).concat(", capacity: ").concat(capacityLimit.toString()))
    }
}

