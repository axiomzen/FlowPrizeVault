import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Projected balance information structure
access(all) struct ProjectedBalanceInfo {
    /// Balance accounting for unsynced yield/deficit in the yield source
    access(all) let projectedBalance: UFix64
    /// Balance based on last-synced share price
    access(all) let syncedBalance: UFix64
    access(all) let shares: UFix64
    /// Share price from last sync
    access(all) let syncedSharePrice: UFix64

    init(
        projectedBalance: UFix64,
        syncedBalance: UFix64,
        shares: UFix64,
        syncedSharePrice: UFix64
    ) {
        self.projectedBalance = projectedBalance
        self.syncedBalance = syncedBalance
        self.shares = shares
        self.syncedSharePrice = syncedSharePrice
    }
}

/// Get a user's projected balance in a pool, accounting for unsynced yield or deficit
/// in the yield source. Returns both the projected (live) and synced (cached) balances
/// so the caller can compare.
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: ProjectedBalanceInfo with live and cached balance data
access(all) fun main(address: Address, poolID: UInt64): ProjectedBalanceInfo {
    let collectionRef = getAccount(address)
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")

    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let receiverID = collectionRef.getReceiverID()

    return ProjectedBalanceInfo(
        projectedBalance: poolRef.getProjectedUserBalance(receiverID: receiverID),
        syncedBalance: poolRef.getReceiverTotalBalance(receiverID: receiverID),
        shares: poolRef.getUserRewardsShares(receiverID: receiverID),
        syncedSharePrice: poolRef.getRewardsSharePrice()
    )
}
