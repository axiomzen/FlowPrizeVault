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
    
    let allocatedLotteryYield = poolRef.getAllocatedLotteryYield()
    let allocatedTreasuryYield = poolRef.getAllocatedTreasuryYield()
    let allocatedSavings = poolRef.allocatedSavings
    
    return {
        "allocatedSavings": allocatedSavings,
        "totalStaked": allocatedSavings,  // Backwards-compatible alias
        "totalAssets": poolRef.getTotalSavingsAssets(),
        "totalShares": poolRef.getTotalSavingsShares(),
        "sharePrice": poolRef.getSavingsSharePrice(),
        "allocatedLotteryYield": allocatedLotteryYield,
        "pendingLotteryYield": allocatedLotteryYield,  // Backwards-compatible alias
        "allocatedTreasuryYield": allocatedTreasuryYield,
        "pendingTreasuryYield": allocatedTreasuryYield,  // Backwards-compatible alias
        "lotteryPoolBalance": poolRef.getLotteryPoolBalance(),
        "unclaimedTreasuryBalance": poolRef.getUnclaimedTreasuryBalance(),
        "availableYieldRewards": poolRef.getAvailableYieldRewards()
    }
}
