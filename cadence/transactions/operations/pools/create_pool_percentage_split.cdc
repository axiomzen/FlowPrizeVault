import "PrizeLinkedAccounts"
import "FlowYieldVaultsConnectorV2"
import "FungibleToken"
import FlowYieldVaults from 0xb1d63873c3cc9f79
import FlowYieldVaultsClosedBeta from 0xb1d63873c3cc9f79
import PMStrategiesV1 from 0xb1d63873c3cc9f79

/// Create Pool — Percentage Split (requires CriticalOps + OwnerOnly — deployer account only).
///
/// Creates a pool where multiple winners split the prize pool by percentage.
/// Uses FlowYieldVaultsConnectorV2 as the mainnet yield source connector.
///
/// prizeSplits must sum to 1.0. Examples:
///   [0.6, 0.4]       → 2 winners: 60% and 40%
///   [0.5, 0.3, 0.2]  → 3 winners: 50%, 30%, 20%
///
/// See create_pool_single_winner.cdc for prerequisite details.
///
/// Signer: deployer account ONLY (OwnerOnly cannot be delegated)
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    rewardsPercent: UFix64,
    prizePercent: UFix64,
    protocolFeePercent: UFix64,
    prizeSplits: [UFix64],
    pathIdentifier: String,
    strategyTypeId: String
) {

    prepare(deployer: auth(Storage, LoadValue, Capabilities) &Account) {
        let adminRef = deployer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("OwnerOnly + CriticalOps required — sign with deployer account")

        let betaBadgeCap = deployer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
            from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        ) ?? panic("No BetaBadge capability found")
        assert(betaBadgeCap.check(), message: "BetaBadge capability is invalid or revoked")

        let yieldVaultManagerCap = deployer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(
            FlowYieldVaults.YieldVaultManagerStoragePath
        )

        let pyusdVaultType = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!

        let strategyType = CompositeType(strategyTypeId)
            ?? panic("Invalid strategy type identifier: ".concat(strategyTypeId))

        let connector = FlowYieldVaultsConnectorV2.createConnectorAndManagerAtPath(
            account: deployer,
            yieldVaultManagerCap: yieldVaultManagerCap,
            betaBadgeCap: betaBadgeCap,
            vaultType: pyusdVaultType,
            strategyType: strategyType,
            pathIdentifier: pathIdentifier
        )

        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            protocolFee: protocolFeePercent
        )

        let prizeDistribution = PrizeLinkedAccounts.PercentageSplit(
            prizeSplits: prizeSplits,
            nftIDs: []
        )

        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: pyusdVaultType,
            yieldConnector: connector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution
        )

        let poolID = adminRef.createPool(config: config, emergencyConfig: nil)

        let pyusdReceiverPath = PublicPath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver")!
        let receiverCap = deployer.capabilities.get<&{FungibleToken.Receiver}>(pyusdReceiverPath)
        if receiverCap.check() {
            adminRef.setPoolProtocolFeeRecipient(poolID: poolID, recipientCap: receiverCap)
        } else {
            log("WARNING: pyUSD receiver not found — run fees/set_protocol_fee_recipient.cdc after setup")
        }

        log("Created PercentageSplit pool ID: ".concat(poolID.toString())
            .concat(" with ").concat(prizeSplits.length.toString()).concat(" winner(s)"))
    }
}
