import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Projected prize pool balance information structure
access(all) struct ProjectedPrizePoolInfo {
    /// Prize pool balance accounting for unsynced yield/deficit in the yield source
    access(all) let projectedPrizePoolBalance: UFix64
    /// Prize pool balance based on last sync (cached)
    access(all) let syncedPrizePoolBalance: UFix64

    init(
        projectedPrizePoolBalance: UFix64,
        syncedPrizePoolBalance: UFix64
    ) {
        self.projectedPrizePoolBalance = projectedPrizePoolBalance
        self.syncedPrizePoolBalance = syncedPrizePoolBalance
    }
}

/// Get a pool's projected prize pool balance, accounting for unsynced yield or deficit
/// in the yield source. Returns both the projected (live) and synced (cached) prize
/// pool balances so the caller can compare.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: ProjectedPrizePoolInfo with live and cached prize pool data
access(all) fun main(poolID: UInt64): ProjectedPrizePoolInfo {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    return ProjectedPrizePoolInfo(
        projectedPrizePoolBalance: poolRef.getProjectedPrizePoolBalance(),
        syncedPrizePoolBalance: poolRef.getPrizePoolBalance()
    )
}
