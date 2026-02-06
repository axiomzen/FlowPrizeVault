import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a pool with SingleWinnerPrize distribution and NFT IDs
/// Uses a 60 second draw interval for testing
transaction(nftIDs: [UInt64]) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultNFT_".concat(currentPoolCount.toString()))!

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
            protocolFee: 0.1
        )

        // Create prize distribution with NFT IDs
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: nftIDs
        ) as {PrizeLinkedAccounts.PrizeDistribution}

        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: mockConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 60.0,  // 60 seconds for testing
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution
        )

        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )

        log("Created pool with ID: ".concat(poolID.toString()).concat(" with NFT prize IDs: ").concat(nftIDs.length.toString()))
    }
}
