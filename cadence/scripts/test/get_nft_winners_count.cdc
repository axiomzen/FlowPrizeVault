import "PrizeWinnerTracker"

/// Get NFT winner count for a pool from the tracker
access(all) fun main(trackerAddress: Address, poolID: UInt64): Int {
    let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress)
        ?? panic("Winner tracker not found at address")

    return tracker.getNFTWinnersCount(poolID: poolID)
}
