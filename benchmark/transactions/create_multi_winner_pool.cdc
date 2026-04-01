import PrizeLinkedAccounts from "../../cadence/contracts/PrizeLinkedAccounts.cdc"
import MockYieldConnector from "../../cadence/contracts/mock/MockYieldConnector.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create a test pool with multiple winners for benchmarking completeDraw computation.
/// Uses PercentageSplit prize distribution with equal splits among winners.
///
/// Parameters:
/// - winnerCount: Number of winners per draw (determines prize splits)
/// - minimumDeposit: Minimum deposit amount
/// - drawIntervalSeconds: Time between draws
transaction(
    winnerCount: Int,
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64
) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let providerCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
    let receiverCap: Capability<&FlowToken.Vault>

    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")

        self.providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            /storage/testYieldVault
        )

        self.receiverCap = signer.capabilities.storage.issue<&FlowToken.Vault>(
            /storage/testYieldVault
        )
    }

    execute {
        // Create yield connector
        let yieldConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: self.providerCap,
            receiverCap: self.receiverCap,
            vaultType: Type<@FlowToken.Vault>()
        )

        // Fixed distribution: 50% rewards, 40% prize, 10% protocolFee
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: 0.5,
            prize: 0.4,
            protocolFee: 0.1
        )

        // Build equal prize splits for N winners
        // Each winner gets 1/N of the prize pool
        var prizeSplits: [UFix64] = []
        let splitAmount = 1.0 / UFix64(winnerCount)

        // For precision, give last winner the remainder
        var remaining: UFix64 = 1.0
        var i = 0
        while i < winnerCount - 1 {
            prizeSplits.append(splitAmount)
            remaining = remaining - splitAmount
            i = i + 1
        }
        // Last winner gets remainder to ensure sum = 1.0
        prizeSplits.append(remaining)

        // Create multi-winner prize distribution
        let prizeDistribution = PrizeLinkedAccounts.PercentageSplit(
            prizeSplits: prizeSplits,
            nftIDs: []  // No NFT prizes for benchmark
        )

        // Create pool config
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: yieldConnector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )

        let poolID = self.adminRef.createPool(
            config: config,
            emergencyConfig: nil
        )

        log("Created multi-winner pool with ID: ".concat(poolID.toString()).concat(", winners: ").concat(winnerCount.toString()))
    }
}
