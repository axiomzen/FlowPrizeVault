import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a pool with FixedAmountTiers distribution
transaction(tierAmounts: [UFix64], tierCounts: [Int], tierNames: [String], tierNFTIDs: [[UInt64]]) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultFAT_".concat(currentPoolCount.toString()))!
        
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)
        
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)
        
        let mockConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: 0.7,
            prize: 0.2,
            treasury: 0.1
        )
        
        // Build prize tiers
        var tiers: [PrizeLinkedAccounts.PrizeTier] = []
        var i = 0
        while i < tierAmounts.length {
            let tier = PrizeLinkedAccounts.PrizeTier(
                amount: tierAmounts[i],
                count: tierCounts[i],
                name: tierNames[i],
                nftIDs: tierNFTIDs[i]
            )
            tiers.append(tier)
            i = i + 1
        }
        
        let prizeDistribution = PrizeLinkedAccounts.FixedAmountTiers(
            tiers: tiers
        ) as {PrizeLinkedAccounts.PrizeDistribution}
        
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 1.0,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )
        
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )
        
        log("Created pool with ID: ".concat(poolID.toString()).concat(" with FixedAmountTiers"))
    }
}

