import PrizeLinkedAccounts from 0xa092c4aab33daeda
import FlowYieldVaultsConnectorV2 from 0xa092c4aab33daeda
import FungibleToken from 0xf233dcee88fe0abe
import FungibleTokenMetadataViews from 0xf233dcee88fe0abe
import FlowYieldVaults from 0xb1d63873c3cc9f79
import FlowYieldVaultsClosedBeta from 0xb1d63873c3cc9f79
import PMStrategiesV1 from 0xb1d63873c3cc9f79
import EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750 from 0x1e4aa0b87d10b141

/// Create a PrizeLinkedAccounts pool using FlowYieldVaultsConnectorV2 with pyUSD and PMStrategiesV1.FUSDEVStrategy
///
/// This transaction:
/// 1. Creates a FlowYieldVaultsConnectorV2 manager + connector (using existing BetaBadge + YieldVaultManager)
/// 2. Creates a PrizeLinkedAccounts pool with the connector and pyUSD as the asset
/// 3. Sets the protocol fee recipient to the signer's pyUSD receiver
///
/// Parameters:
/// - minimumDeposit: Minimum deposit amount in pyUSD (e.g., 1.0)
/// - drawIntervalSeconds: Time between prize draws in seconds (e.g., 604800.0 for 7 days)
/// - rewardsPercent: Percentage of yield to savings interest (e.g., 0.35 = 35%)
/// - prizePercent: Percentage of yield to prize pool (e.g., 0.65 = 65%)
/// - protocolFeePercent: Percentage of yield to protocol treasury (e.g., 0.0 = 0%)
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    rewardsPercent: UFix64,
    prizePercent: UFix64,
    protocolFeePercent: UFix64
) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin
    let connector: FlowYieldVaultsConnectorV2.Connector
    let treasuryReceiverCap: Capability<&{FungibleToken.Receiver}>

    prepare(signer: auth(Storage, Capabilities, BorrowValue) &Account) {
        // 1. Borrow the PrizeLinkedAccounts Admin
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("PrizeLinkedAccounts Admin not found")

        // 2. Issue capability for the YieldVaultManager resource
        let yieldVaultManagerPath = StoragePath(identifier: "FlowYieldVaultsYieldVaultManager_0xb1d63873c3cc9f79")!
        let yieldVaultManagerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(yieldVaultManagerPath)

        // 3. Copy the BetaBadge capability from storage
        let betaBadgeCap = signer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
            from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        ) ?? panic("BetaBadge capability not found in storage. Run claim_beta.cdc first.")

        // 4. Create the V2 connector + manager wrapper
        self.connector = FlowYieldVaultsConnectorV2.createConnectorAndManager(
            account: signer,
            yieldVaultManagerCap: yieldVaultManagerCap,
            betaBadgeCap: betaBadgeCap,
            vaultType: Type<@EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>(),
            strategyType: Type<@PMStrategiesV1.FUSDEVStrategy>()
        )

        // 5. Get the pyUSD receiver capability for protocol fee treasury
        let vaultData = EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.resolveContractView(
            resourceType: nil,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for pyUSD")

        self.treasuryReceiverCap = signer.capabilities.get<&{FungibleToken.Receiver}>(vaultData.receiverPath)
        assert(self.treasuryReceiverCap.check(), message: "Signer must have a valid pyUSD receiver capability")
    }

    execute {
        // Create distribution strategy
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            protocolFee: protocolFeePercent
        )

        // Create single winner prize distribution (winner takes all)
        let prizeDistribution = PrizeLinkedAccounts.SingleWinnerPrize(nftIDs: [])

        // Create pool config with pyUSD as the asset type
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>(),
            yieldConnector: self.connector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution
        )

        // Create the pool
        let poolID = self.adminRef.createPool(
            config: config,
            emergencyConfig: nil
        )

        // Set the treasury recipient to the signer's pyUSD receiver
        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: self.treasuryReceiverCap
        )

        log("Created pyUSD pool with ID: ".concat(poolID.toString()))
    }
}
