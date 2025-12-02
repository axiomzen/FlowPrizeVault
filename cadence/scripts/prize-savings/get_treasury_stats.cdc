import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Treasury statistics structure
access(all) struct TreasuryStats {
    access(all) let balance: UFix64
    access(all) let totalCollected: UFix64
    access(all) let totalWithdrawn: UFix64
    access(all) let fundingStats: {String: UFix64}
    
    init(
        balance: UFix64,
        totalCollected: UFix64,
        totalWithdrawn: UFix64,
        fundingStats: {String: UFix64}
    ) {
        self.balance = balance
        self.totalCollected = totalCollected
        self.totalWithdrawn = totalWithdrawn
        self.fundingStats = fundingStats
    }
}

/// Get treasury statistics for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: TreasuryStats struct with treasury information
access(all) fun main(poolID: UInt64): TreasuryStats {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let stats = poolRef.getTreasuryStats()
    
    return TreasuryStats(
        balance: stats["balance"] ?? 0.0,
        totalCollected: stats["totalCollected"] ?? 0.0,
        totalWithdrawn: stats["totalWithdrawn"] ?? 0.0,
        fundingStats: poolRef.getFundingStats()
    )
}

