import "PrizeLinkedAccounts"
import "FlowYieldVaultsConnectorV2"
import "FungibleToken"
import FlowYieldVaults from 0xb1d63873c3cc9f79
import FlowYieldVaultsClosedBeta from 0xb1d63873c3cc9f79
import PMStrategiesV1 from 0xb1d63873c3cc9f79

/// Create a new pool using a FRESH PMStrategiesV1.FUSDEVStrategy resource.
///
/// WHY: The PMStrategiesV1 contract was updated in-place to add Morpho/ERC4626 swap connectors,
/// but Pool0's existing strategy resource was created before that update and only has AMM swappers.
/// Creating a NEW strategy resource picks up the Morpho ERC4626 connectors.
///
/// APPROACH: Uses FlowYieldVaultsConnectorV2.createConnectorAndManagerAtPath() to create a
/// YieldVaultManagerWrapper at a custom storage path, avoiding collision with Pool0's wrapper.
///
/// PREREQUISITE: The deployer must already have a valid BetaBadge capability stored at
/// FlowYieldVaultsClosedBeta.UserBetaCapStoragePath (granted during original Pool0 setup).
///
/// Single signer (deployer / a092c4aab33daeda):
///
/// Usage:
/// flow transactions send cadence/transactions/prize-linked-accounts/create_pool_morpho_strategy.cdc \
///   --network mainnet \
///   --signer mainnet-deployer \
///   --compute-limit 9999

transaction {

    prepare(
        deployer: auth(Storage, BorrowValue, Capabilities) &Account
    ) {
        // === Load existing BetaBadge capability from deployer's storage ===
        let betaBadgeCap = deployer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
            from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        ) ?? panic("No BetaBadge capability found at UserBetaCapStoragePath. Was grantBeta() called for this account?")

        assert(betaBadgeCap.check(), message: "BetaBadge capability is invalid or revoked")

        // === Issue YieldVaultManager capability ===
        // The deployer already has a YieldVaultManager from Pool0 setup.
        // Issue a new capability for the same manager — the new wrapper will create
        // a separate YieldVault inside it (with a fresh FUSDEVStrategy that has Morpho connectors).
        let yieldVaultManagerCap = deployer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(
            FlowYieldVaults.YieldVaultManagerStoragePath
        )

        // pyUSD vault type (EVM-bridged token on Flow)
        let pyusdVaultType = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!

        // PMStrategiesV1.FUSDEVStrategy — now includes Morpho ERC4626 connectors
        let strategyType = Type<@PMStrategiesV1.FUSDEVStrategy>()

        // === Create connector at custom path (avoids collision with Pool0's wrapper) ===
        let connector = FlowYieldVaultsConnectorV2.createConnectorAndManagerAtPath(
            account: deployer,
            yieldVaultManagerCap: yieldVaultManagerCap,
            betaBadgeCap: betaBadgeCap,
            vaultType: pyusdVaultType,
            strategyType: strategyType,
            pathIdentifier: "flowYieldVaultsManagerV2_morpho_a092c4aab33daeda"
        )

        // === Create Pool with fresh FUSDEVStrategy connector ===
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: 0.5,
            prize: 0.4,
            protocolFee: 0.1
        )

        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(nftIDs: [])

        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: pyusdVaultType,
            yieldConnector: connector,
            minimumDeposit: 0.01,
            drawIntervalSeconds: 604800.0,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution
        )

        let adminRef = deployer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")

        let poolID = adminRef.createPool(
            config: config,
            emergencyConfig: nil
        )

        log("Created fresh FUSDEVStrategy pool with ID: ".concat(poolID.toString()))

        // Set protocol fee recipient (pyUSD receiver on deployer's account)
        let pyusdReceiverPath = PublicPath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver")!
        let receiverCap = deployer.capabilities.get<&{FungibleToken.Receiver}>(pyusdReceiverPath)
        if receiverCap.check() {
            adminRef.setPoolProtocolFeeRecipient(
                poolID: poolID,
                recipientCap: receiverCap
            )
            log("Set protocol fee recipient for pool ".concat(poolID.toString()))
        } else {
            log("WARNING: No pyUSD receiver found at public path — skipping protocol fee recipient setup")
        }
    }
}
