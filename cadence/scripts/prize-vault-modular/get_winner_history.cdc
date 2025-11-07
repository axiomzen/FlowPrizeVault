import PrizeWinnerTracker from "../../contracts/PrizeWinnerTracker.cdc"

/// Get recent winners for a specific pool
/// 
/// Parameters:
/// - trackerAddress: Address where the PrizeWinnerTracker is deployed
/// - poolID: The pool ID to query winners for
/// - limit: Maximum number of winners to return (default: 10)
/// 
/// Returns: Array of WinnerRecord structs
access(all) fun main(trackerAddress: Address, poolID: UInt64, limit: Int): [PrizeWinnerTracker.WinnerRecord] {
    if let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress) {
        return tracker.getRecentWinners(poolID: poolID, limit: limit)
    }
    return []
}

