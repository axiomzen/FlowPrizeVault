/*
Initialize PrizeVault Scheduler

Sets up the unified scheduler handler for automated prize draws across all pools.
This transaction must be run once before scheduling any pool draws.

The scheduler:
- Manages all pools from a single handler
- Each pool can have its own draw frequency
- Automatically chains draws: start → complete → next start
- Uses a centralized fee vault

Example usage:
flow transactions send cadence/transactions/init_scheduler.cdc \
  --network emulator --signer emulator-account

After initialization, use schedule_pool_draw.cdc to register pools.
*/

import PrizeVaultScheduler from "../contracts/PrizeVaultScheduler.cdc"
import "FlowTransactionSchedulerUtils"
import "FlowTransactionScheduler"
import "FlowToken"
import "FungibleToken"

transaction() {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Step 1: Create FlowTransactionSchedulerUtils.Manager if needed
        if !signer.storage.check<@{FlowTransactionSchedulerUtils.Manager}>(
            from: FlowTransactionSchedulerUtils.managerStoragePath
        ) {
            log("Creating FlowTransactionSchedulerUtils.Manager...")
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)
            
            // Create public capability for the manager
            let managerCap = signer.capabilities.storage.issue<&{FlowTransactionSchedulerUtils.Manager}>(
                FlowTransactionSchedulerUtils.managerStoragePath
            )
            signer.capabilities.publish(managerCap, at: FlowTransactionSchedulerUtils.managerPublicPath)
            
            log("✅ FlowTransactionSchedulerUtils.Manager created")
        } else {
            log("✓ FlowTransactionSchedulerUtils.Manager already exists")
        }
        
        // Step 2: Create fee withdrawal capability
        // This allows the handler to withdraw FLOW for transaction fees
        let feeWithdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            /storage/flowTokenVault
        )
        
        // Verify the capability is valid
        assert(feeWithdrawCap.check(), message: "Invalid fee withdrawal capability")
        
        log("✅ Fee withdrawal capability created")
        
        // Step 3: Check if handler already exists and destroy it if so
        if signer.storage.check<@PrizeVaultScheduler.Handler>(from: PrizeVaultScheduler.HandlerStoragePath) {
            log("⚠️  Destroying existing handler...")
            let oldHandler <- signer.storage.load<@PrizeVaultScheduler.Handler>(
                from: PrizeVaultScheduler.HandlerStoragePath
            )
            destroy oldHandler
        }
        
        // Step 4: Create entitled capability for the handler (before creating it)
        // This capability allows scheduled transactions to execute the handler
        let handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}> = 
            signer.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                PrizeVaultScheduler.HandlerStoragePath
            )
        
        log("✅ Handler capability created")
        
        // Step 5: Issue manager capability with Owner authorization
        let managerCap = signer.capabilities.storage.issue<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
            FlowTransactionSchedulerUtils.managerStoragePath
        )
        
        assert(managerCap.check(), message: "Invalid manager capability")
        log("✅ Manager capability issued")
        
        // Step 6: Create the unified scheduler handler
        let handler <- PrizeVaultScheduler.createHandler(
            vaultModularAddress: signer.address,
            feeWithdrawCap: feeWithdrawCap,
            handlerCap: handlerCap,
            managerCap: managerCap
        )
        
        log("✅ Unified scheduler handler created")
        
        // Step 7: Save handler to storage
        signer.storage.save(<-handler, to: PrizeVaultScheduler.HandlerStoragePath)
        log("✅ Handler saved to storage")
        
        // Step 8: Create and publish public (read-only) capability for status checks
        let publicHandlerCap = signer.capabilities.storage.issue<&PrizeVaultScheduler.Handler>(
            PrizeVaultScheduler.HandlerStoragePath
        )
        signer.capabilities.publish(publicHandlerCap, at: PrizeVaultScheduler.HandlerPublicPath)
        
        log("✅ Public handler capability published")
        
        // Step 9: Get current FLOW balance
        let vaultRef = signer.storage.borrow<&FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
        
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("✅ PrizeVault Scheduler initialized successfully!")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("📍 Handler Address: ".concat(signer.address.toString()))
        log("💰 Current FLOW Balance: ".concat(vaultRef.balance.toString()))
        log("")
        log("⚠️  IMPORTANT: Ensure sufficient FLOW balance for fees")
        log("   Recommended: > 10.0 FLOW for continuous operation")
        log("")
        log("📋 Next Steps:")
        log("   1. Fund the scheduler with FLOW (optional)")
        log("   2. Register pools: schedule_pool_draw.cdc")
        log("   3. Monitor: get_scheduler_status.cdc")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}

