import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Projected share price information structure
access(all) struct ProjectedSharePriceInfo {
    /// Share price accounting for unsynced yield/deficit in the yield source
    access(all) let projectedSharePrice: UFix64
    /// Share price from last sync (cached)
    access(all) let syncedSharePrice: UFix64

    init(
        projectedSharePrice: UFix64,
        syncedSharePrice: UFix64
    ) {
        self.projectedSharePrice = projectedSharePrice
        self.syncedSharePrice = syncedSharePrice
    }
}

/// Get a pool's projected share price, accounting for unsynced yield or deficit
/// in the yield source. Returns both the projected (live) and synced (cached) share
/// price so the caller can compare.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: ProjectedSharePriceInfo with live and cached share price data
access(all) fun main(poolID: UInt64): ProjectedSharePriceInfo {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    return ProjectedSharePriceInfo(
        projectedSharePrice: poolRef.getProjectedSharePrice(),
        syncedSharePrice: poolRef.getRewardsSharePrice()
    )
}
