import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "MockYieldConnector"

/// Transaction to create a test pool with a SlippageVaultConnector that charges
/// a configurable deposit fee (in basis points). Used for testing deposit slippage
/// accounting reconciliation.
///
/// Parameters:
/// - rewardsPercent: Rewards distribution percentage (e.g., 0.7 = 70%)
/// - prizePercent: Prize distribution percentage (e.g., 0.2 = 20%)
/// - protocolFeePercent: Protocol fee percentage (e.g., 0.1 = 10%)
/// - depositFeeBps: Deposit fee in basis points (e.g., 200 = 2%)
transaction(rewardsPercent: UFix64, prizePercent: UFix64, protocolFeePercent: UFix64, depositFeeBps: UInt64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Generate unique storage path based on current pool count to avoid collisions
        let currentPoolCount = PrizeLinkedAccounts.getAllPoolIDs().length
        let vaultPath = StoragePath(identifier: "testYieldVaultSlippage_".concat(currentPoolCount.toString()))!
        let feeSinkPath = StoragePath(identifier: "testFeeSinkVault_".concat(currentPoolCount.toString()))!

        // Create a test vault to use as yield source
        let testVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-testVault, to: vaultPath)

        // Create a fee sink vault to absorb deposit fees
        let feeSinkVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-feeSinkVault, to: feeSinkPath)

        // Create capabilities for the yield vault
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(vaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)

        // Create capability for the fee sink vault
        let feeSinkCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(feeSinkPath)

        // Create slippage connector
        let slippageConnector = MockYieldConnector.createSlippageVaultConnector(
            providerCap: withdrawCap,
            receiverCap: depositCap,
            feeSinkCap: feeSinkCap,
            vaultType: Type<@FlowToken.Vault>(),
            depositFeeBps: depositFeeBps
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

        // Create pool config
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: slippageConnector,
            minimumDeposit: 1.0,
            drawIntervalSeconds: 1.0,
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

        log("Created slippage pool with ID: ".concat(poolID.toString())
            .concat(", depositFeeBps: ").concat(depositFeeBps.toString()))
    }
}
