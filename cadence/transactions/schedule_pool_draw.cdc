/*
Schedule Pool Draw

Registers a pool with the scheduler and schedules its first automated draw.
The scheduler will then automatically continue the draw cycle indefinitely.

Draw Cycle:
1. startDraw() executes at scheduled time (commits to randomness)
2. completeDraw() automatically scheduled for next block
3. completeDraw() awards prize and schedules next startDraw()
4. Cycle repeats based on pool's drawIntervalSeconds configuration

Parameters:
- poolID: The ID of the prize pool to schedule draws for

NOTE: The scheduler automatically derives timing from the pool's drawIntervalSeconds
configuration. This ensures all draws stay aligned with the pool's time schedule.

Example usage:
flow transactions send cadence/transactions/schedule_pool_draw.cdc \
  --network emulator --signer emulator-account \
  --args-json '[{"type":"UInt64","value":"0"}]'
*/

import PrizeVaultScheduler from "../contracts/PrizeVaultScheduler.cdc"
import PrizeVaultModular from "../contracts/PrizeVaultModular.cdc"
import "FlowToken"

transaction(poolID: UInt64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Verify pool exists
        let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist: ".concat(poolID.toString()))
        
        log("✓ Pool ".concat(poolID.toString()).concat(" found"))
        
        // Get pool config for display
        let config = poolRef.getConfig()
        let roundDurationSeconds = config.drawIntervalSeconds
        
        // Get the handler with contract access
        let handler = signer.storage.borrow<&PrizeVaultScheduler.Handler>(
            from: PrizeVaultScheduler.HandlerStoragePath
        ) ?? panic("Could not borrow Handler. Have you run init_scheduler.cdc?")
        
        log("✓ Scheduler handler found")
        
        // Check if pool is already registered
        if handler.isPoolRegistered(poolID: poolID) {
            log("Pool already registered with scheduler")
            log("   To restart scheduling, unregister first then register again")
            log("   Skipping registration to avoid errors")
        } else {
            // Register the pool - automatically schedules first draw
            handler.registerPool(poolID: poolID)
            log("Pool registered with scheduler and first draw scheduled automatically")
        }
        
        // Check fee balance
        let feeBalance = handler.getFeeBalance()
        log("💰 Current fee balance: ".concat(feeBalance.toString()).concat(" FLOW"))
        
        if feeBalance < 0.5 {
            log("⚠️  WARNING: Fee balance is low!")
            log("   Consider funding with more FLOW to ensure continuous operation")
            log("   Estimated fees per draw: ~0.01 FLOW")
        }
        
        // Verify pool can draw
        let poolAuthRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
            ?? panic("Cannot borrow pool with auth")
        
        if poolAuthRef.isDrawInProgress() {
            log("⚠️  WARNING: A draw is already in progress for this pool")
            log("   Complete the current draw before scheduling new ones")
        }
        
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("SCHEDULING CONFIGURATION")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("Pool ID: ".concat(poolID.toString()))
        log("Draw Interval: ".concat(roundDurationSeconds.toString()).concat(" seconds"))
        log("   (~".concat((roundDurationSeconds / 60.0).toString()).concat(" minutes)"))
        log("   (~".concat((roundDurationSeconds / 3600.0).toString()).concat(" hours)"))
        log("   (~".concat((roundDurationSeconds / 86400.0).toString()).concat(" days)"))
        log("Timing auto-aligned with pool's time schedule")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        log("")
        log("✅ FIRST PRIZE DRAW SCHEDULED SUCCESSFULLY!")
        log("🎯 Automated Draw Cycle Started")
        log("   • startDraw will execute at the configured time")
        log("   • completeDraw will be auto-scheduled (~1 second later)")
        log("   • Next startDraw will be auto-scheduled after configured interval")
        log("   • Cycle continues indefinitely, aligned with pool config")
        log("")
        log("Monitor Status:")
        log("   flow scripts execute cadence/scripts/get_scheduler_status.cdc")
    }
}

