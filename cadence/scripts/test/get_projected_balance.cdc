import "PrizeLinkedAccounts"

/// Get a user's projected balance in a pool, accounting for unsync'd yield or deficit.
/// Returns both the projected and actual balance for comparison.
///
/// Parameters:
/// - userAddress: The user's address
/// - poolID: The pool ID to check
///
/// Returns: Dictionary with:
///   - "projectedBalance": Balance if sync happened now
///   - "actualBalance": Current balance (last synced share price)
///   - "shares": Number of shares held
///   - "sharePrice": Current share price (before projection)
access(all) fun main(userAddress: Address, poolID: UInt64): {String: UFix64} {
    let account = getAccount(userAddress)

    let collectionRef = account.capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found at address")

    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let receiverID = collectionRef.uuid

    let projectedBalance = poolRef.getProjectedUserBalance(receiverID: receiverID)
    let actualBalance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
    let shares = poolRef.getUserRewardsShares(receiverID: receiverID)
    let sharePrice = poolRef.getRewardsSharePrice()

    return {
        "projectedBalance": projectedBalance,
        "actualBalance": actualBalance,
        "shares": shares,
        "sharePrice": sharePrice
    }
}
