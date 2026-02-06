import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get detailed rewards and allocation info for a pool
/// Useful for testing deficit/excess handling
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with rewards and allocation details
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return {
        "userPoolBalance": poolRef.userPoolBalance,
        "totalAssets": poolRef.getTotalRewardsAssets(),
        "totalShares": poolRef.getTotalRewardsShares(),
        "sharePrice": poolRef.getRewardsSharePrice(),
        "allocatedPrizeYield": poolRef.getAllocatedPrizeYield(),
        "allocatedProtocolFee": poolRef.getAllocatedProtocolFee(),
        "prizePoolBalance": poolRef.getPrizePoolBalance(),
        "unclaimedProtocolBalance": poolRef.getUnclaimedProtocolBalance(),
        "availableYieldRewards": poolRef.getAvailableYieldRewards()
    }
}
