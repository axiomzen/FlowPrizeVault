import "PrizeSavings"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "TestHelpers"

/// Transaction to create a pool with FixedPrizeTiers strategy
transaction(tierAmounts: [UFix64], tierCounts: [Int], tierNames: [String], tierNFTIDs: [[UInt64]]) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeSavings.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultFT_".concat(currentPoolCount.toString()))!
        
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)
        
        let mockConnector = TestHelpers.SimpleVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        let distributionStrategy = PrizeSavings.FixedPercentageStrategy(
            savings: 0.7,
            lottery: 0.2,
            treasury: 0.1
        )
        
        // Build prize tiers
        var tiers: [PrizeSavings.PrizeTier] = []
        var i = 0
        while i < tierAmounts.length {
            let tier = PrizeSavings.PrizeTier(
                amount: tierAmounts[i],
                count: tierCounts[i],
                name: tierNames[i],
                nftIDs: tierNFTIDs[i]
            )
            tiers.append(tier)
            i = i + 1
        }
        
        let winnerStrategy = PrizeSavings.FixedPrizeTiers(
            tiers: tiers
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
        
        let admin = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil,
            fundingPolicy: nil,
            createdBy: signer.address
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with FixedPrizeTiers"))
    }
}

