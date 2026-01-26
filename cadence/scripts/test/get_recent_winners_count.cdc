import "PrizeWinnerTracker"

/// Get the count of recent winners for a pool (up to the specified limit)
access(all) fun main(trackerAddress: Address, poolID: UInt64, limit: Int): Int {
    let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress)
        ?? panic("Winner tracker not found at address")

    let winners = tracker.getRecentWinners(poolID: poolID, limit: limit)
    return winners.length
}
