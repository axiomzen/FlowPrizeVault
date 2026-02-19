import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with a TruncatingVaultConnector that
/// truncates withdrawals to 6 decimal places (simulating EVM bridge behavior).
///
/// Parameters:
/// - rewardsPercent: Rewards distribution percentage (e.g., 0.7 = 70%)
/// - prizePercent: Prize distribution percentage (e.g., 0.2 = 20%)
/// - protocolFeePercent: Protocol fee percentage (e.g., 0.1 = 10%)
transaction(rewardsPercent: UFix64, prizePercent: UFix64, protocolFeePercent: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultTruncating_".concat(currentPoolCount.toString()))!

        // Create a test vault to use as yield source
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)

        // Create capabilities for the yield vault
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)

        // Create truncating connector
        let truncatingConnector = MockYieldConnector.createTruncatingVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )

        // Create custom distribution strategy
        let strategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            protocolFee: protocolFeePercent
        )

        // Create prize distribution
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(
            nftIDs: []
        ) as {PrizeLinkedAccounts.PrizeDistribution}

        // Create pool config with short draw interval for testing
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: truncatingConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 1.0,
            distributionStrategy: strategy,
            prizeDistribution: prizeDistribution
        )

        // Borrow admin resource and create pool
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let poolID = admin.createPool(
            config: config,
            emergencyConfig: nil
        )

        log("Created truncating pool with ID: ".concat(poolID.toString()))
    }
}
