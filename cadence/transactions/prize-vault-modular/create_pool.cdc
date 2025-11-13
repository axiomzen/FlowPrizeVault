import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"
import PrizeVaultScheduler from "../../contracts/PrizeVaultScheduler.cdc"
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
/// - drawIntervalSeconds: Time interval in seconds between draws (defines the pool's draw frequency)
/// - trackerAddress: Optional address where PrizeWinnerTracker is deployed (use 0x0 for no tracker)
/// - autoSchedule: Whether to automatically register with scheduler and start draws
///
/// NOTE: When autoSchedule is true, the scheduler will automatically derive timing from
/// the pool's drawIntervalSeconds configuration. No manual time parameters needed!
transaction(
    savingsPercent: UFix64,
    lotteryPercent: UFix64,
    treasuryPercent: UFix64,
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    trackerAddress: Address?,
    autoSchedule: Bool
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
        
        // Create a test vault to hold rewards (will be refilled by test script)
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
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: strategy,
            winnerSelectionStrategy: winnerStrategy,
            winnerTrackerCap: trackerCap
        )
        
        // Create the pool
        let poolID = PrizeVaultModular.createPool(config: config)
        
        log("Pool created with ID: ".concat(poolID.toString()))
        log("Distribution: ".concat(strategy.getStrategyName()))
        log("Winner Selection: ".concat(winnerStrategy.getStrategyName()))
        log("Min deposit: ".concat(minimumDeposit.toString()).concat(" FLOW"))
        log("Draw interval: ".concat(drawIntervalSeconds.toString()).concat(" seconds"))
        log("Test vault: ".concat(testVaultPath.toString()))
        
        if trackerCap != nil {
            log("📝 Winner tracking: Enabled")
        } else {
            log("📝 Winner tracking: Disabled")
        }
        
        // Auto-register with scheduler if requested
        if autoSchedule {
            let handler = signer.storage.borrow<&PrizeVaultScheduler.Handler>(
                from: PrizeVaultScheduler.HandlerStoragePath
            )
            
            if handler == nil {
                log("⚠️  WARNING: Scheduler not initialized. Run init_scheduler.cdc first.")
                log("   Pool created but NOT registered with scheduler.")
                log("   Use schedule_pool_draw.cdc to register later.")
            } else {
                // Register pool - automatically schedules first draw using pool's configuration
                handler!.registerPool(poolID: poolID)
                
                // Get pool config for display
                let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)!
                let config = poolRef.getConfig()
                let roundDurationSeconds = config.drawIntervalSeconds
                
                log("")
                log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                log("Automated Draws Configured")
                log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                log("Draw Interval: ".concat(roundDurationSeconds.toString()).concat(" seconds"))
                log("   (~".concat((roundDurationSeconds / 60.0).toString()).concat(" minutes)"))
                log("   (~".concat((roundDurationSeconds / 3600.0).toString()).concat(" hours)"))
                log("   (~".concat((roundDurationSeconds / 86400.0).toString()).concat(" days)"))
                log("Draws will stay aligned with pool's time schedule")
                log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            }
        }
    }
}
