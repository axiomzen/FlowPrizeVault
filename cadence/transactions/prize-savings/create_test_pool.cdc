import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import TestHelpers from "../../contracts/TestHelpers.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create Test Pool transaction - Creates a new PrizeSavings pool using TestHelpers.SimpleVaultConnector
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
    let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
    let receiverCap: Capability<&{FungibleToken.Receiver}>
    let signerAddress: Address
    
    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Store signer address for use in execute block
        self.signerAddress = signer.address
        
        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found. Only the contract deployer can create pools.")
        
        // Get the provider capability for the test yield vault
        self.providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(
            /storage/testYieldVault
        )
        
        // Get the receiver capability for the test yield vault  
        self.receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(
            /storage/testYieldVault
        )
    }
    
    execute {
        // Create the yield connector using TestHelpers
        let yieldConnector = TestHelpers.SimpleVaultConnector(
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
        
        // Create winner selection strategy (single winner takes all)
        let winnerStrategy = PrizeSavings.WeightedSingleWinner(nftIDs: [])
        
        // Create pool config
        let config = PrizeSavings.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: yieldConnector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            winnerSelectionStrategy: winnerStrategy,
            winnerTrackerCap: nil
        )
        
        // Create the pool
        let poolID = self.adminRef.createPool(
            config: config,
            emergencyConfig: nil,  // Uses defaults
            fundingPolicy: nil,    // Uses defaults
            createdBy: self.signerAddress
        )
        
        log("Created pool with ID: ".concat(poolID.toString()))
    }
}

