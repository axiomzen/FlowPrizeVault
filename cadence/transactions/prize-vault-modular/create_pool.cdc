import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"
import PrizeWinnerTracker from "../../contracts/PrizeWinnerTracker.cdc"
import TestHelpers from "../../contracts/TestHelpers.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create a test pool using TestHelpers mock connectors
///
/// Parameters:
/// - savingsPercent: Percentage for savings (0.0-1.0)
/// - lotteryPercent: Percentage for lottery (0.0-1.0)
/// - treasuryPercent: Percentage for treasury (0.0-1.0)
/// - minimumDeposit: Minimum deposit amount
/// - blocksPerDraw: Number of blocks between draws
/// - trackerAddress: Optional address where PrizeWinnerTracker is deployed (use 0x0 for no tracker)
transaction(
    savingsPercent: UFix64,
    lotteryPercent: UFix64,
    treasuryPercent: UFix64,
    minimumDeposit: UFix64,
    blocksPerDraw: UInt64,
    trackerAddress: Address?
) {
    
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Create distribution strategy
        let strategy = PrizeVaultModular.FixedPercentageStrategy(
            savings: savingsPercent,
            lottery: lotteryPercent,
            treasury: treasuryPercent
        )
        
        // Create winner selection strategy (default: single winner)
        let winnerStrategy = PrizeVaultModular.WeightedSingleWinner()
        
        // Create a test vault to hold staked tokens
        let testVaultPath = StoragePath(identifier: "testYieldVault_".concat(getCurrentBlock().height.toString()))!
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-emptyVault, to: testVaultPath)
        
        // Create capabilities
        let withdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>(testVaultPath)
        let depositCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(testVaultPath)
        
        // Create test helpers with mock implementations
        let mockSink = TestHelpers.SimpleVaultSink(
            receiverCap: depositCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        let mockSource = TestHelpers.SimpleVaultSource(
            providerCap: withdrawCap,
            vaultType: Type<@FlowToken.Vault>()
        )
        
        // Get tracker capability (optional)
        var trackerCap: Capability<&{PrizeWinnerTracker.WinnerTrackerPublic}>? = nil
        if let address = trackerAddress {
            if address != 0x0 {
                let account = getAccount(address)
                trackerCap = account.capabilities.get<&{PrizeWinnerTracker.WinnerTrackerPublic}>(
                    PrizeWinnerTracker.TrackerPublicPath
                )
                
                // Verify capability is valid
                if trackerCap != nil {
                    let trackerRef = trackerCap!.borrow()
                    if trackerRef == nil {
                        log("⚠️  Warning: Tracker capability found but cannot be borrowed")
                        trackerCap = nil
                    }
                } else {
                    log("⚠️  Warning: No tracker capability found at address ".concat(address.toString()))
                }
            }
        }
        
        // Create pool config
        let config = PrizeVaultModular.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldSink: mockSink,
            yieldSource: mockSource,
            priceOracle: nil,
            instantSwapper: nil,
            minimumDeposit: minimumDeposit,
            blocksPerDraw: blocksPerDraw,
            distributionStrategy: strategy,
            winnerSelectionStrategy: winnerStrategy,
            winnerTrackerCap: trackerCap
        )
        
        // Create the pool
        let poolID = PrizeVaultModular.createPool(config: config)
        
        log("✅ Pool created with ID: ".concat(poolID.toString()))
        log("📊 Distribution: ".concat(strategy.getStrategyName()))
        log("🏆 Winner Selection: ".concat(winnerStrategy.getStrategyName()))
        log("💰 Min deposit: ".concat(minimumDeposit.toString()).concat(" FLOW"))
        log("🎲 Blocks per draw: ".concat(blocksPerDraw.toString()))
        log("🗄️  Test vault: ".concat(testVaultPath.toString()))
        
        if trackerCap != nil {
            log("📝 Winner tracking: Enabled")
        } else {
            log("📝 Winner tracking: Disabled")
        }
    }
}
