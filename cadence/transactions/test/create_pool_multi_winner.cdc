import "PrizeSavings"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a pool with PercentageSplit distribution
transaction(splits: [UFix64], nftIDs: [UInt64]) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeSavings.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultPS_".concat(currentPoolCount.toString()))!
        
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)
        
        let mockConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        let distributionStrategy = PrizeSavings.FixedPercentageStrategy(
            savings: 0.7,
            lottery: 0.2,
            treasury: 0.1
        )
        
        let prizeDistribution = PrizeSavings.PercentageSplit(
            prizeSplits: splits,
            nftIDs: nftIDs
        ) as {PrizeSavings.PrizeDistribution}
        
        let config = PrizeSavings.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 60.0,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )
        
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with PercentageSplit"))
    }
}

