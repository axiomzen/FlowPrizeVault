import "PrizeLinkedAccounts"

/// Get detailed share price and precision info for precision testing
/// This script provides all the data needed to verify share price stability
/// and detect precision-related issues.
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Dictionary with:
///   - "sharePrice": Current share price (assets per share)
///   - "totalAssets": Total assets under management
///   - "totalShares": Total shares outstanding
///   - "effectiveAssets": totalAssets + VIRTUAL_ASSETS
///   - "effectiveShares": totalShares + VIRTUAL_SHARES
///   - "virtualAssets": VIRTUAL_ASSETS constant
///   - "virtualShares": VIRTUAL_SHARES constant
///   - "totalAllocatedFunds": Total allocated funds across all buckets (savings + lottery + treasury)
///   - "totalDistributed": Cumulative yield distributed
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let totalAssets = poolRef.getTotalRewardsAssets()
    let totalShares = poolRef.getTotalRewardsShares()
    let sharePrice = poolRef.getRewardsSharePrice()
    
    // Virtual offsets from contract constants
    let virtualAssets = PrizeLinkedAccounts.VIRTUAL_ASSETS
    let virtualShares = PrizeLinkedAccounts.VIRTUAL_SHARES
    
    // Log values for debugging
    log("VIRTUAL_ASSETS: ".concat(virtualAssets.toString()))
    log("VIRTUAL_SHARES: ".concat(virtualShares.toString()))
    log("sharePrice: ".concat(sharePrice.toString()))
    log("totalAssets: ".concat(totalAssets.toString()))
    log("totalShares: ".concat(totalShares.toString()))
    
    return {
        "sharePrice": sharePrice,
        "totalAssets": totalAssets,
        "totalShares": totalShares,
        "effectiveAssets": totalAssets + virtualAssets,
        "effectiveShares": totalShares + virtualShares,
        "virtualAssets": virtualAssets,
        "virtualShares": virtualShares,
        "totalAllocatedFunds": poolRef.getTotalAllocatedFunds(),
        "totalDistributed": poolRef.getTotalRewardsDistributed()
    }
}

