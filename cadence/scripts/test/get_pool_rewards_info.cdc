import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get detailed savings and allocation info for a pool
/// Useful for testing deficit/excess handling
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with savings and allocation details
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return {
        "allocatedRewards": poolRef.allocatedRewards,
        "totalAssets": poolRef.getTotalRewardsAssets(),
        "totalShares": poolRef.getTotalRewardsShares(),
        "sharePrice": poolRef.getRewardsSharePrice(),
        "allocatedPrizeYield": poolRef.getAllocatedLotteryYield(),
        "allocatedTreasuryYield": poolRef.getAllocatedTreasuryYield(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "unclaimedTreasuryBalance": poolRef.getUnclaimedTreasuryBalance(),
        "availableYieldRewards": poolRef.getAvailableYieldRewards()
    }
}
