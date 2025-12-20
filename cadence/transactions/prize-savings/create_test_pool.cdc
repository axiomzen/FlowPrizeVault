import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import MockYieldConnector from "../../contracts/mock/MockYieldConnector.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create Test Pool transaction - Creates a new PrizeSavings pool using MockYieldConnector.SimpleVaultConnector
/// This is specifically for testing with the emulator
///
/// Parameters:
/// - minimumDeposit: Minimum deposit amount required
/// - drawIntervalSeconds: Time between lottery draws (e.g., 10.0 for 10 seconds in testing)
/// - savingsPercent: Percentage of yield going to savings (e.g., 0.5 for 50%)
/// - lotteryPercent: Percentage of yield going to lottery (e.g., 0.4 for 40%)
/// - treasuryPercent: Percentage of yield going to treasury (e.g., 0.1 for 10%)
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    savingsPercent: UFix64,
    lotteryPercent: UFix64,
    treasuryPercent: UFix64
) {
    
    let adminRef: auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin
    let providerCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
    let receiverCap: Capability<&FlowToken.Vault>
    
    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
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
        let distributionStrategy = PrizeSavings.FixedPercentageStrategy(
            savings: savingsPercent,
            lottery: lotteryPercent,
            treasury: treasuryPercent
        )
        
        // Create prize distribution (single winner takes all)
        let prizeDistribution = PrizeSavings.SingleWinnerPrize(nftIDs: [])
        
        // Create pool config
        let config = PrizeSavings.PoolConfig(
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
        
        log("Created pool with ID: ".concat(poolID.toString()))
    }
}

