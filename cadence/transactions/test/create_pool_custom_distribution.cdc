import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with custom distribution strategy
transaction(rewardsPercent: UFix64, prizePercent: UFix64, treasuryPercent: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultDist_".concat(currentPoolCount.toString()))!
        
        // Create a test vault to use as yield source
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        // Create capabilities for the connector
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)
        
        // Create mock connector using MockYieldConnector
        let mockConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        // Create custom distribution strategy
        let strategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            treasury: treasuryPercent
        )
        
        // Create prize distribution
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeLinkedAccounts.PrizeDistribution}
        
        // Create pool config
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 86400.0,
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
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with custom distribution"))
    }
}

