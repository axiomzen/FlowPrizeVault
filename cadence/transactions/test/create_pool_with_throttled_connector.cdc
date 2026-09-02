import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Creates a test pool backed by a ThrottledLiquidityConnector: the position is fully
/// intact but only `liquidityCap` can be withdrawn at any moment. Models a Morpho
/// Vault V2 whose liquidity adapter has been cleared.
///
/// - rewardsPercent / prizePercent / protocolFeePercent: yield split
/// - liquidityCap: ceiling on what the connector reports as withdrawable
transaction(rewardsPercent: UFix64, prizePercent: UFix64, protocolFeePercent: UFix64, liquidityCap: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultThrottled_".concat(currentPoolCount.toString()))!

        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)

        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)

        let throttledConnector = MockYieldConnector.createThrottledLiquidityConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>(),
            liquidityCap: liquidityCap
        )

        let strategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            protocolFee: protocolFeePercent
        )

        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeLinkedAccounts.PrizeDistribution}

        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: throttledConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 1.0,
            distributionStrategy: strategy,
            prizeDistribution: prizeDistribution
        )

        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let poolID = admin.createPool(config: config, emergencyConfig: nil)

        log("Created throttled pool with ID: ".concat(poolID.toString())
            .concat(", liquidityCap: ").concat(liquidityCap.toString()))
    }
}
