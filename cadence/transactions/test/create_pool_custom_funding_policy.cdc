import "PrizeSavings"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a pool with custom funding policy
/// Uses 0.0 to represent nil (unlimited)
/// Note: Treasury funding is no longer supported - treasury auto-forwards during reward processing
transaction(maxDirectLottery: UFix64, maxDirectSavings: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeSavings.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultFP_".concat(currentPoolCount.toString()))!
        
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
        
        let winnerStrategy = PrizeSavings.WeightedSingleWinner(
            nftIDs: []
        ) as {PrizeSavings.WinnerSelectionStrategy}
        
        let config = PrizeSavings.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 1.0,
            distributionStrategy: distributionStrategy,
            winnerSelectionStrategy: winnerStrategy,
            winnerTrackerCap: nil
        )
        
        // Create custom funding policy
        // Use nil when value is 0.0 to represent unlimited
        let fundingPolicy = PrizeSavings.FundingPolicy(
            maxDirectLottery: maxDirectLottery > 0.0 ? maxDirectLottery : nil,
            maxDirectSavings: maxDirectSavings > 0.0 ? maxDirectSavings : nil
        )
        
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil,
            fundingPolicy: fundingPolicy,
            createdBy: signer.address
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with custom funding policy"))
    }
}

