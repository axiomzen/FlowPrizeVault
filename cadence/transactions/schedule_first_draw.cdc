/*
⚠️  DEPRECATED: Use schedule_pool_draw.cdc instead

This file is deprecated in favor of the unified scheduler approach.
Please use: cadence/transactions/schedule_pool_draw.cdc

Schedule First Prize Draw

Kicks off the automated prize draw cycle for a specific pool.
Run this once after initializing the scheduler to start automated draws.

The scheduled transaction will:
1. Call startDraw() at the specified time (commits to randomness)
2. Automatically schedule completeDraw() for the next block
3. completeDraw() will award the prize and schedule the next startDraw()
4. This cycle continues indefinitely

Parameters:
- poolID: The ID of the prize pool to schedule draws for
- delaySeconds: How long to wait before the first draw (e.g., 60.0 for 1 minute)

Example usage (schedule first draw in 1 minute for testing):
flow transactions send cadence/transactions/schedule_first_draw.cdc \
  --network emulator --signer emulator-account \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"60.0"}
  ]'

For immediate execution (after minimum delay):
flow transactions send cadence/transactions/schedule_first_draw.cdc \
  --network emulator --signer emulator-account \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"10.0"}
  ]'
*/

import "PrizeVaultScheduler"
import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"
import "PrizeVaultModular"

transaction(poolID: UInt64, delaySeconds: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Verify pool exists
        let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist: ".concat(poolID.toString()))
        
        log("Found pool ".concat(poolID.toString()))
        
        // Get the manager with Owner authorization
        let manager = signer.storage.borrow<auth(FlowTransactionSchedulerUtils.Owner) &FlowTransactionSchedulerUtils.ManagerV1>(
            from: FlowTransactionSchedulerUtils.managerStoragePath
        ) ?? panic("Could not borrow Manager. Have you run init_scheduler.cdc?")
        
        log("Manager found")
        
        // Get handler capability
        let controllers = signer.capabilities.storage.getControllers(
            forPath: PrizeVaultScheduler.HandlerStoragePath
        )
        
        assert(controllers.length > 0, message: "No handler found. Have you run init_scheduler.cdc?")
        
        var handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? = nil
        for controller in controllers {
            if let cap = controller.capability as? Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}> {
                handlerCap = cap
                break
            }
        }
        
        assert(handlerCap != nil, message: "Could not find valid handler capability")
        log("Handler capability found")
        
        // Verify handler has access to fees
        let handlerRef = signer.storage.borrow<&PrizeVaultScheduler.Handler>(
            from: PrizeVaultScheduler.HandlerStoragePath
        ) ?? panic("Could not borrow handler")
        
        let currentFeeBalance = handlerRef.getFeeBalance()
        log("Current fee balance: ".concat(currentFeeBalance.toString()).concat(" FLOW"))
        
        if currentFeeBalance < 0.1 {
            log("⚠️  Warning: Fee balance is low. Ensure sufficient FLOW in account.")
        }
        
        
        // Calculate execution time
        let executionTime = getCurrentBlock().timestamp + delaySeconds

        log("Current time: ".concat(getCurrentBlock().timestamp.toString()))
        log("Execution time: ".concat(executionTime.toString()))
        
        // Create draw data for startDraw
        let drawData = PrizeVaultScheduler.DrawData(
            poolID: poolID,
            drawType: PrizeVaultScheduler.DrawType.Start
        )
        
        // Estimate fees for this transaction
        let feeEstimate = FlowTransactionScheduler.estimate(
            data: drawData,
            timestamp: executionTime,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 2000
        )
        
        log("Estimated fee: ".concat((feeEstimate.flowFee ?? 0.01).toString()).concat(" FLOW"))
        
        // Withdraw fees from account
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
        
        let feeAmount = feeEstimate.flowFee ?? 0.01
        let fees <- vaultRef.withdraw(amount: feeAmount) as! @FlowToken.Vault
        
        log("Withdrew ".concat(feeAmount.toString()).concat(" FLOW for fees"))
        
        log("Current time: ".concat(getCurrentBlock().timestamp.toString()))
        log("Execution time: ".concat(executionTime.toString()))
        
        // Schedule the first startDraw
        manager.schedule(
            handlerCap: handlerCap!,
            data: drawData,
            timestamp: executionTime,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 2000,
            fees: <-fees
        )
        
        log("First prize draw scheduled successfully!")
        log("   Pool ID: ".concat(poolID.toString()))
        log("   Draw type: START")
        log("   Execution time: ".concat(executionTime.toString()))
        log("   Delay: ".concat(delaySeconds.toString()).concat(" seconds"))
        log("")
        log("The automated draw cycle has begun!")
        log("1. startDraw will execute at ".concat(executionTime.toString()))
        log("2. completeDraw will be scheduled for the next block")
        log("3. Next startDraw will be scheduled automatically")
        log("4. This cycle will continue indefinitely")
    }
}

