import "PrizeWinnerTracker"

/// Get the pool IDs from recent winners
access(all) fun main(trackerAddress: Address, poolID: UInt64, limit: Int): [UInt64] {
    let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress)
        ?? panic("Winner tracker not found at address")

    let winners = tracker.getRecentWinners(poolID: poolID, limit: limit)
    var poolIDs: [UInt64] = []
    for winner in winners {
        poolIDs.append(winner.poolID)
    }
    return poolIDs
}
