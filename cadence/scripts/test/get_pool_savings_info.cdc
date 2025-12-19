import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Get detailed savings and allocation info for a pool
/// Useful for testing deficit/excess handling
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with savings and allocation details
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return {
        "totalStaked": poolRef.totalStaked,
        "totalDeposited": poolRef.totalDeposited,
        "totalAssets": poolRef.getTotalSavingsAssets(),
        "totalShares": poolRef.getTotalSavingsShares(),
        "sharePrice": poolRef.getSavingsSharePrice(),
        "pendingLotteryYield": poolRef.getPendingLotteryYield(),
        "pendingTreasuryYield": poolRef.getPendingTreasuryYield(),
        "lotteryPoolBalance": poolRef.getLotteryPoolBalance(),
        "unclaimedTreasuryBalance": poolRef.getUnclaimedTreasuryBalance(),
        "availableYieldRewards": poolRef.getAvailableYieldRewards()
    }
}
