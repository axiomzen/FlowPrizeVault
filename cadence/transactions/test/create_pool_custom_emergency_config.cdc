import "PrizeSavings"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a pool with custom emergency config
transaction(
    maxEmergencyDuration: UFix64,
    autoRecoveryEnabled: Bool,
    minYieldSourceHealth: UFix64,
    maxWithdrawFailures: Int,
    partialModeDepositLimit: UFix64,
    minBalanceThreshold: UFix64,
    minRecoveryHealth: UFix64
) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeSavings.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultEC_".concat(currentPoolCount.toString()))!
        
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
        
        // Create custom emergency config
        let emergencyConfig = PrizeSavings.EmergencyConfig(
            maxEmergencyDuration: maxEmergencyDuration,
            autoRecoveryEnabled: autoRecoveryEnabled,
            minYieldSourceHealth: minYieldSourceHealth,
            maxWithdrawFailures: maxWithdrawFailures,
            partialModeDepositLimit: partialModeDepositLimit,
            minBalanceThreshold: minBalanceThreshold,
            minRecoveryHealth: minRecoveryHealth
        )
        
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: emergencyConfig,
            fundingPolicy: nil,
            createdBy: signer.address
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with custom emergency config"))
    }
}

