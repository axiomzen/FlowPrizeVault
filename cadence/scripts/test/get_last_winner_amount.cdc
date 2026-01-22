import "PrizeWinnerTracker"

/// Get the prize amount of the most recent winner for a pool
access(all) fun main(trackerAddress: Address, poolID: UInt64): UFix64 {
    let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress)
        ?? panic("Winner tracker not found at address")

    let winners = tracker.getRecentWinners(poolID: poolID, limit: 1)
    if winners.length == 0 {
        return 0.0
    }
    return winners[0].amount
}
