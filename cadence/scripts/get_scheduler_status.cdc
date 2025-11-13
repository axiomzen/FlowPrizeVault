/*
Get Scheduler Status

Queries the PrizeVault Scheduler to see all managed pools and their status.

Example usage:
flow scripts execute cadence/scripts/get_scheduler_status.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0xf8d6e0586b0a20c7"}]'
*/

import PrizeVaultScheduler from "../contracts/PrizeVaultScheduler.cdc"
import PrizeVaultModular from "../contracts/PrizeVaultModular.cdc"

access(all) struct PoolScheduleStatus {
    access(all) let poolID: UInt64
    access(all) let roundDurationSeconds: UFix64
    access(all) let roundDurationDays: UFix64
    access(all) let isRegistered: Bool  // Pool is enabled if it's in the registry
    access(all) let lastExecutionTime: UFix64?
    access(all) let timeSinceLastDraw: UFix64?
    access(all) let poolExists: Bool
    access(all) let canDrawNow: Bool
    access(all) let drawInProgress: Bool
    
    init(
        poolID: UInt64,
        roundDurationSeconds: UFix64,
        isRegistered: Bool,
        lastExecutionTime: UFix64?,
        poolExists: Bool,
        canDrawNow: Bool,
        drawInProgress: Bool,
        currentTime: UFix64
    ) {
        self.poolID = poolID
        self.roundDurationSeconds = roundDurationSeconds
        self.roundDurationDays = roundDurationSeconds / 86400.0
        self.isRegistered = isRegistered
        self.lastExecutionTime = lastExecutionTime
        self.poolExists = poolExists
        self.canDrawNow = canDrawNow
        self.drawInProgress = drawInProgress
        
        if let lastTime = lastExecutionTime {
            self.timeSinceLastDraw = currentTime - lastTime
        } else {
            self.timeSinceLastDraw = nil
        }
    }
}

access(all) struct SchedulerStatus {
    access(all) let handlerAddress: Address
    access(all) let feeBalance: UFix64
    access(all) let managedPoolCount: Int
    access(all) let pools: [PoolScheduleStatus]
    access(all) let currentTime: UFix64
    access(all) let isInitialized: Bool
    
    init(
        handlerAddress: Address,
        feeBalance: UFix64,
        managedPoolCount: Int,
        pools: [PoolScheduleStatus],
        currentTime: UFix64,
        isInitialized: Bool
    ) {
        self.handlerAddress = handlerAddress
        self.feeBalance = feeBalance
        self.managedPoolCount = managedPoolCount
        self.pools = pools
        self.currentTime = currentTime
        self.isInitialized = isInitialized
    }
}

access(all) fun main(handlerAddress: Address): SchedulerStatus {
    let currentTime = getCurrentBlock().timestamp
    
    // Get handler from public capability
    let account = getAccount(handlerAddress)
    let handlerCap = account.capabilities.get<&PrizeVaultScheduler.Handler>(
        PrizeVaultScheduler.HandlerPublicPath
    )
    
    if !handlerCap.check() {
        // Handler not initialized
        return SchedulerStatus(
            handlerAddress: handlerAddress,
            feeBalance: 0.0,
            managedPoolCount: 0,
            pools: [],
            currentTime: currentTime,
            isInitialized: false
        )
    }
    
    let handler = handlerCap.borrow()!
    
    // Get all managed pools
    let poolIDs = handler.getAllManagedPools()
    let poolStatuses: [PoolScheduleStatus] = []
    
    for poolID in poolIDs {
        // Check if pool is registered (in the registry)
        let isRegistered = handler.isPoolRegistered(poolID: poolID)
        let lastExecTime = handler.getLastExecutionTime(poolID: poolID)
        
        // Get draw interval from pool directly
        let drawInterval = handler.getPoolDrawInterval(poolID: poolID) ?? 0.0
        
        // Check if pool exists
        let poolRef = PrizeVaultModular.borrowPool(poolID: poolID)
        let poolExists = poolRef != nil
        var canDrawNow = false
        var drawInProgress = false
        
        if let pool = poolRef {
            canDrawNow = pool.canDrawNow()
            drawInProgress = pool.isDrawInProgress()
        }
        
        let status = PoolScheduleStatus(
            poolID: poolID,
            roundDurationSeconds: drawInterval,
            isRegistered: isRegistered,
            lastExecutionTime: lastExecTime,
            poolExists: poolExists,
            canDrawNow: canDrawNow,
            drawInProgress: drawInProgress,
            currentTime: currentTime
        )
        
        poolStatuses.append(status)
    }
    
    return SchedulerStatus(
        handlerAddress: handlerAddress,
        feeBalance: handler.getFeeBalance(),
        managedPoolCount: poolIDs.length,
        pools: poolStatuses,
        currentTime: currentTime,
        isInitialized: true
    )
}
