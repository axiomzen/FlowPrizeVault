/*
PrizeVaultScheduler - Automated Prize Draw Scheduling

Manages automated prize draws for all PrizeVaultModular pools using a single
unified scheduler handler. The scheduler maintains a simple registry of active
pools and always queries pool configuration directly from PrizeVaultModular.

Key Features:
- Single handler manages all pools
- Pool configuration queried directly from source (PrizeVaultModular)
- Auto-scheduling after each draw completes
- Centralized fee management
- Graceful error handling
- Simple registry-based pool tracking
*/

import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FungibleToken"
import "FlowToken"
import "PrizeVaultModular"
import "ViewResolver"

access(all) contract PrizeVaultScheduler {
    
    // ========================================
    // Constants
    // ========================================
    
    // ========================================
    // Storage Paths
    // ========================================
    
    access(all) let HandlerStoragePath: StoragePath
    access(all) let HandlerPublicPath: PublicPath
    access(all) let FeeVaultStoragePath: StoragePath
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event SchedulerInitialized(handlerAddress: Address)
    access(all) event PoolRegistered(poolID: UInt64)
    access(all) event PoolUnregistered(poolID: UInt64)
    access(all) event DrawScheduled(poolID: UInt64, drawType: String, executionTime: UFix64)
    access(all) event DrawExecuted(poolID: UInt64, drawType: String, success: Bool, error: String?)
    access(all) event FeesFunded(amount: UFix64, newBalance: UFix64)
    access(all) event FeesWithdrawn(amount: UFix64, purpose: String)
    
    // ========================================
    // Draw Data Structure
    // ========================================
    
    access(all) enum DrawType: UInt8 {
        access(all) case Start
        access(all) case Complete
    }
    
    access(all) struct DrawData {
        access(all) let poolID: UInt64
        access(all) let drawType: DrawType
        
        init(poolID: UInt64, drawType: DrawType) {
            self.poolID = poolID
            self.drawType = drawType
        }
        
        access(all) fun getDrawTypeName(): String {
            switch self.drawType {
                case DrawType.Start:
                    return "START"
                case DrawType.Complete:
                    return "COMPLETE"
            }
            return "UNKNOWN"
        }
    }
    
    // ========================================
    // Handler Resource
    // ========================================
    
    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {
        // Account address where PrizeVaultModular is deployed
        access(self) let vaultModularAddress: Address
        
        // Capabilities for fee management and scheduling
        access(self) let feeWithdrawCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
        access(self) let handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
        access(self) let managerCap: Capability<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>
        
        // Pool registry - tracks which pools are actively being scheduled
        // If a poolID is not in this registry, scheduling will stop for that pool
        access(self) let managedPools: {UInt64: Bool}
        
        // Schedule tracking
        access(self) let lastExecutionTime: {UInt64: UFix64}
        
        init(
            vaultModularAddress: Address,
            feeWithdrawCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>,
            handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            managerCap: Capability<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>
        ) {
            self.vaultModularAddress = vaultModularAddress
            self.feeWithdrawCap = feeWithdrawCap
            self.handlerCap = handlerCap
            self.managerCap = managerCap
            self.managedPools = {}
            self.lastExecutionTime = {}
        }
        
        // ========================================
        // ViewResolver Interface (required by TransactionHandler)
        // ========================================
        
        access(all) view fun getViews(): [Type] {
            return [Type<PublicPath>()]
        }
        
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            if view == Type<PublicPath>() {
                return PrizeVaultScheduler.HandlerPublicPath
            }
            return nil
        }
        
        // ========================================
        // FlowTransactionScheduler Interface
        // ========================================
        
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let drawData = data as! DrawData
            let poolID = drawData.poolID
            
            // Verify pool is in registry (actively being scheduled)
            if self.managedPools[poolID] != true {
                let error = "Pool ".concat(poolID.toString()).concat(" is not registered with scheduler - stopping scheduling")
                return
            }
            
            // Get pool reference
            let poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
            if poolRef == nil {
                let error = "Cannot borrow pool ".concat(poolID.toString())
                emit DrawExecuted(poolID: poolID, drawType: drawData.getDrawTypeName(), success: false, error: error)
                return
            }
            
            // Execute based on draw type
            var success = false
            var errorMessage: String? = nil
            
            switch drawData.drawType {
                case DrawType.Start:
                    // Execute startDraw
                    poolRef!.startDraw()
                    success = true
                    
                    // Schedule completeDraw for next block (~1 second later)
                    self.scheduleCompleteDraw(poolID: poolID)
                    
                case DrawType.Complete:
                    // Execute completeDraw
                    poolRef!.completeDraw()
                    success = true
                    
                    // Schedule next draw based on pool's configuration
                    self.scheduleNextDraw(poolID: poolID)
            }
            
            // Update last execution time
            self.lastExecutionTime[poolID] = getCurrentBlock().timestamp
            
            emit DrawExecuted(
                poolID: poolID,
                drawType: drawData.getDrawTypeName(),
                success: success,
                error: errorMessage
            )
        }
        
        // ========================================
        // Pool Management
        // ========================================
        
        /// Register a pool for scheduling
        /// This adds the pool to the active registry and automatically schedules the next draw
        /// All pool configuration will be queried directly from PrizeVaultModular
        access(all) fun registerPool(poolID: UInt64) {
            pre {
                self.managedPools[poolID] != true: "Pool already registered"
            }
            
            // Verify pool exists
            let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
                ?? panic("Pool does not exist: ".concat(poolID.toString()))
            
            // Add to registry
            self.managedPools[poolID] = true
            
            emit PoolRegistered(poolID: poolID)
            
            // Automatically schedule the next draw based on pool configuration
            self.scheduleNextDraw(poolID: poolID)
        }
        
        /// Unregister a pool from scheduling
        /// Removes the pool from the registry - future scheduled draws will not execute
        access(all) fun unregisterPool(poolID: UInt64) {
            pre {
                self.managedPools[poolID] == true: "Pool not registered"
            }
            
            self.managedPools.remove(key: poolID)
            self.lastExecutionTime.remove(key: poolID)
            
            emit PoolUnregistered(poolID: poolID)
        }
        
        // ========================================
        // Scheduling Functions
        // ========================================
        
        /// Schedule the next draw for a registered pool
        /// Calculates timing based on pool's drawIntervalSeconds and lastDrawTimestamp
        /// Queries all configuration directly from PrizeVaultModular
        /// This is called automatically by registerPool() and after completeDraw()
        access(self) fun scheduleNextDraw(poolID: UInt64) {
            // Verify pool is still in registry
            if self.managedPools[poolID] != true {
                return
            }
            
            // Get pool reference and read its state
            let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
            if poolRef == nil {
                return
            }
            
            let config = poolRef!.getConfig()
            let lastDrawTimestamp = poolRef!.lastDrawTimestamp
            let currentTimestamp = getCurrentBlock().timestamp
            let drawIntervalSeconds = config.drawIntervalSeconds
            
            // Calculate delay in seconds based on pool configuration
            let delaySeconds = self.calculateDelayFromPoolConfig(
                lastDrawTimestamp: lastDrawTimestamp,
                currentTimestamp: currentTimestamp,
                drawIntervalSeconds: drawIntervalSeconds
            )
            
            let executionTime = getCurrentBlock().timestamp + delaySeconds
            
            let drawData = DrawData(
                poolID: poolID,
                drawType: DrawType.Start
            )
            
            self.scheduleTransaction(
                data: drawData,
                executionTime: executionTime
            )
        }
        
        /// Helper function to calculate delay seconds from pool configuration
        access(self) fun calculateDelayFromPoolConfig(
            lastDrawTimestamp: UFix64,
            currentTimestamp: UFix64,
            drawIntervalSeconds: UFix64
        ): UFix64 {
            // Pool has never had a draw - schedule immediately (minimum delay)
            if lastDrawTimestamp == 0.0 {
                return 1.0
            }
            
            let timeSinceLastDraw = currentTimestamp - lastDrawTimestamp
            
            // We're overdue - schedule immediately
            if timeSinceLastDraw >= drawIntervalSeconds {
                return 1.0
            }
            
            // Calculate time remaining until next scheduled draw
            let timeUntilNextDraw = drawIntervalSeconds - timeSinceLastDraw
            return timeUntilNextDraw
        }
        
        access(self) fun scheduleCompleteDraw(poolID: UInt64) {
            // Schedule for next block (approximately 1 second)
            let executionTime = getCurrentBlock().timestamp + 1.0
            
            let drawData = DrawData(
                poolID: poolID,
                drawType: DrawType.Complete
            )
            
            self.scheduleTransaction(
                data: drawData,
                executionTime: executionTime
            )
        }
        
        access(self) fun scheduleTransaction(data: DrawData, executionTime: UFix64) {
            // Get manager
            let manager = self.managerCap.borrow()
                ?? panic("Cannot borrow manager")
            
            // Estimate fees
            let feeEstimate = FlowTransactionScheduler.estimate(
                data: data,
                timestamp: executionTime,
                priority: FlowTransactionScheduler.Priority.Medium,
                executionEffort: 2000
            )
            
            let feeAmount = feeEstimate.flowFee ?? 0.01
            
            // Withdraw fees from capability
            let feeVault = self.feeWithdrawCap.borrow()
                ?? panic("Cannot borrow fee vault")
            
            let fees <- feeVault.withdraw(amount: feeAmount) as! @FlowToken.Vault
            
            emit FeesWithdrawn(amount: feeAmount, purpose: "Scheduled draw for pool ".concat(data.poolID.toString()))
            
            // Schedule the transaction
            manager.schedule(
                handlerCap: self.handlerCap,
                data: data,
                timestamp: executionTime,
                priority: FlowTransactionScheduler.Priority.Medium,
                executionEffort: 2000,
                fees: <-fees
            )
            
            emit DrawScheduled(
                poolID: data.poolID,
                drawType: data.getDrawTypeName(),
                executionTime: executionTime
            )
        }
        
        // ========================================
        // Getters
        // ========================================
        
        access(all) fun isPoolRegistered(poolID: UInt64): Bool {
            return self.managedPools[poolID] == true
        }
        
        access(all) fun getAllManagedPools(): [UInt64] {
            return self.managedPools.keys
        }
        
        access(all) fun getLastExecutionTime(poolID: UInt64): UFix64? {
            return self.lastExecutionTime[poolID]
        }
        
        access(all) fun getFeeBalance(): UFix64 {
            if let vault = self.feeWithdrawCap.borrow() {
                return vault.balance
            }
            return 0.0
        }
        
        /// Get the draw interval directly from the pool's configuration
        access(all) fun getPoolDrawInterval(poolID: UInt64): UFix64? {
            if let poolRef = PrizeVaultModular.borrowPool(poolID: poolID) {
                let config = poolRef.getConfig()
                return config.drawIntervalSeconds
            }
            return nil
        }
        
        /// Get the last draw timestamp directly from the pool
        access(all) fun getPoolLastDrawTime(poolID: UInt64): UFix64? {
            if let poolRef = PrizeVaultModular.borrowPool(poolID: poolID) {
                return poolRef.lastDrawTimestamp
            }
            return nil
        }
    }
    
    // ========================================
    // Contract Functions
    // ========================================
    
    access(all) fun createHandler(
        vaultModularAddress: Address,
        feeWithdrawCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>,
        handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
        managerCap: Capability<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>
    ): @Handler {
        return <- create Handler(
            vaultModularAddress: vaultModularAddress,
            feeWithdrawCap: feeWithdrawCap,
            handlerCap: handlerCap,
            managerCap: managerCap
        )
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.HandlerStoragePath = /storage/PrizeVaultSchedulerHandler
        self.HandlerPublicPath = /public/PrizeVaultSchedulerHandler
        self.FeeVaultStoragePath = /storage/PrizeVaultSchedulerFeeVault
    }
}

