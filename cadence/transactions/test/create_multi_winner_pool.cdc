import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import MockYieldConnector from "../../contracts/mock/MockYieldConnector.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create Multi-Winner Pool transaction - Creates a pool with multiple winners for benchmarking.
/// Uses PercentageSplit prize distribution to test winner selection performance.
///
/// Parameters:
/// - minimumDeposit: Minimum deposit amount required
/// - drawIntervalSeconds: Time between lottery draws
/// - savingsPercent: Percentage of yield going to savings
/// - lotteryPercent: Percentage of yield going to lottery
/// - treasuryPercent: Percentage of yield going to treasury
/// - winnerCount: Number of winners per draw (for benchmarking winner selection)
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    savingsPercent: UFix64,
    lotteryPercent: UFix64,
    treasuryPercent: UFix64,
    winnerCount: Int
) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let providerCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
    let receiverCap: Capability<&FlowToken.Vault>

    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found. Only the contract deployer can create pools.")

        // Get the provider capability for the test yield vault
        self.providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            /storage/testYieldVault
        )

        // Get the receiver capability for the test yield vault
        self.receiverCap = signer.capabilities.storage.issue<&FlowToken.Vault>(
            /storage/testYieldVault
        )
    }

    execute {
        // Create the yield connector using MockYieldConnector
        let yieldConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: self.providerCap,
            receiverCap: self.receiverCap,
            vaultType: Type<@FlowToken.Vault>()
        )

        // Create distribution strategy
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            savings: savingsPercent,
            lottery: lotteryPercent,
            treasury: treasuryPercent
        )

        // Create prize distribution with multiple winners (equal split)
        var prizeSplits: [UFix64] = []
        let splitAmount = 1.0 / UFix64(winnerCount)

        // Build splits array - last winner gets remainder to ensure sum = 1.0
        var runningTotal: UFix64 = 0.0
        for i in InclusiveRange(1, winnerCount) {
            if i == winnerCount {
                // Last winner gets remainder
                prizeSplits.append(1.0 - runningTotal)
            } else {
                prizeSplits.append(splitAmount)
                runningTotal = runningTotal + splitAmount
            }
        }

        let prizeDistribution = PrizeLinkedAccounts.PercentageSplit(prizeSplits: prizeSplits, nftIDs: [])

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

        // Create the pool
        let poolID = self.adminRef.createPool(
            config: config,
            emergencyConfig: nil  // Uses defaults
        )

        log("Created pool with ID: ".concat(poolID.toString()).concat(" with ").concat(winnerCount.toString()).concat(" winners"))
    }
}
