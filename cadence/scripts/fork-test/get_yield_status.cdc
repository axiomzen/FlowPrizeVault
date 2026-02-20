import "PrizeLinkedAccounts"

/// Fork-test: Real-time yield source status
///
/// Returns live data from the yield source compared to cached pool accounting.
/// Use this to see pending yield before it's synced to the pool.
///
/// Key fields:
/// - yieldSourceBalance: Actual balance in yield source (real-time)
/// - totalAllocatedFunds: Sum of cached allocations (userPoolBalance + prizeYield + protocolFee)
/// - pendingYield: Unsynced yield (positive = gains, negative = deficit)
/// - needsSync: Whether syncWithYieldSource would change anything

access(all) struct YieldStatus {
    /// Actual balance in the yield source (real-time query)
    access(all) let yieldSourceBalance: UFix64

    /// Sum of all allocated funds (cached value)
    access(all) let totalAllocatedFunds: UFix64

    /// Breakdown of allocated funds
    access(all) let userPoolBalance: UFix64
    access(all) let allocatedPrizeYield: UFix64
    access(all) let allocatedProtocolFee: UFix64

    /// Pending yield to be synced (yieldSourceBalance - totalAllocatedFunds)
    /// Positive = yield gains, Negative = deficit/loss
    access(all) let pendingYield: Fix64

    /// Whether the pool needs to sync with yield source
    access(all) let needsSync: Bool

    /// Available yield rewards (same as getAvailableYieldRewards)
    access(all) let availableYieldRewards: UFix64

    init(
        yieldSourceBalance: UFix64,
        totalAllocatedFunds: UFix64,
        userPoolBalance: UFix64,
        allocatedPrizeYield: UFix64,
        allocatedProtocolFee: UFix64,
        pendingYield: Fix64,
        needsSync: Bool,
        availableYieldRewards: UFix64
    ) {
        self.yieldSourceBalance = yieldSourceBalance
        self.totalAllocatedFunds = totalAllocatedFunds
        self.userPoolBalance = userPoolBalance
        self.allocatedPrizeYield = allocatedPrizeYield
        self.allocatedProtocolFee = allocatedProtocolFee
        self.pendingYield = pendingYield
        self.needsSync = needsSync
        self.availableYieldRewards = availableYieldRewards
    }
}

/// Get real-time yield source status for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: YieldStatus struct with live and cached yield data
access(all) fun main(poolID: UInt64): YieldStatus {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let yieldSourceBalance = poolRef.getYieldSourceBalance()
    let totalAllocatedFunds = poolRef.getTotalAllocatedFunds()

    // Calculate pending yield (can be negative for deficit)
    var pendingYield: Fix64 = 0.0
    if yieldSourceBalance >= totalAllocatedFunds {
        pendingYield = Fix64(yieldSourceBalance - totalAllocatedFunds)
    } else {
        pendingYield = -Fix64(totalAllocatedFunds - yieldSourceBalance)
    }

    return YieldStatus(
        yieldSourceBalance: yieldSourceBalance,
        totalAllocatedFunds: totalAllocatedFunds,
        userPoolBalance: poolRef.getUserPoolBalance(),
        allocatedPrizeYield: poolRef.getAllocatedPrizeYield(),
        allocatedProtocolFee: poolRef.getAllocatedProtocolFee(),
        pendingYield: pendingYield,
        needsSync: poolRef.needsSync(),
        availableYieldRewards: poolRef.getAvailableYieldRewards()
    )
}
