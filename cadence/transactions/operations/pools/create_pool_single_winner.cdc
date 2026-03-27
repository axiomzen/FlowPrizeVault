import "PrizeLinkedAccounts"
import "FlowYieldVaultsConnectorV2"
import "FungibleToken"
import FlowYieldVaults from 0xb1d63873c3cc9f79
import FlowYieldVaultsClosedBeta from 0xb1d63873c3cc9f79
import PMStrategiesV1 from 0xb1d63873c3cc9f79

/// Create Pool — Single Winner (requires CriticalOps + OwnerOnly — deployer account only).
///
/// Creates a pool where one winner takes the entire prize pool each draw.
/// Uses FlowYieldVaultsConnectorV2 as the mainnet yield source connector.
///
/// PREREQUISITES:
///   1. Deployer account has a YieldVaultManager at FlowYieldVaults.YieldVaultManagerStoragePath
///   2. Deployer has a BetaBadge capability at FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
///   3. The vaultType matches the pool's token (pyUSD on mainnet)
///
/// Adapt pathIdentifier to be unique per pool (avoids storage path collision).
///
/// Signer: deployer account ONLY (OwnerOnly cannot be delegated)
///
/// Parameters:
///   minimumDeposit       — minimum deposit amount in pool tokens
///   drawIntervalSeconds  — seconds between draws (e.g., 604800.0 = weekly)
///   rewardsPercent       — fraction of yield to savings (e.g., 0.5)
///   prizePercent         — fraction of yield to prize pool (e.g., 0.4)
///   protocolFeePercent   — fraction of yield to protocol treasury (e.g., 0.1)
///   pathIdentifier       — unique storage path suffix (e.g., "flowYieldVaultsManagerV2_pool1")
///   strategyTypeId       — fully qualified strategy type (e.g., "A.addr.PMStrategiesV1.FUSDEVStrategy")
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    rewardsPercent: UFix64,
    prizePercent: UFix64,
    protocolFeePercent: UFix64,
    pathIdentifier: String,
    strategyTypeId: String
) {

    prepare(deployer: auth(Storage, LoadValue, Capabilities) &Account) {
        let adminRef = deployer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("OwnerOnly + CriticalOps required — sign with deployer account")

        let betaBadgeCap = deployer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
            from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        ) ?? panic("No BetaBadge capability found. Was grantBeta() called for this account?")
        assert(betaBadgeCap.check(), message: "BetaBadge capability is invalid or revoked")

        let yieldVaultManagerCap = deployer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(
            FlowYieldVaults.YieldVaultManagerStoragePath
        )

        // pyUSD vault type (EVM-bridged token on Flow mainnet)
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

        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(nftIDs: [])

        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: pyusdVaultType,
            yieldConnector: connector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution
        )

        let poolID = adminRef.createPool(config: config, emergencyConfig: nil)

        // Set protocol fee recipient to deployer's pyUSD receiver (update path if needed)
        let pyusdReceiverPath = PublicPath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver")!
        let receiverCap = deployer.capabilities.get<&{FungibleToken.Receiver}>(pyusdReceiverPath)
        if receiverCap.check() {
            adminRef.setPoolProtocolFeeRecipient(poolID: poolID, recipientCap: receiverCap)
        } else {
            log("WARNING: pyUSD receiver not found — run fees/set_protocol_fee_recipient.cdc after setup")
        }

        log("Created SingleWinner pool ID: ".concat(poolID.toString()))
    }
}
