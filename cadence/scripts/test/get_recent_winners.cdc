import "PrizeWinnerTracker"

/// Get recent winners from the tracker
access(all) fun main(trackerAddress: Address, poolID: UInt64, limit: Int): [{String: AnyStruct}] {
    let tracker = PrizeWinnerTracker.borrowTracker(account: trackerAddress)
        ?? panic("Winner tracker not found at address")

    let winners = tracker.getRecentWinners(poolID: poolID, limit: limit)

    var result: [{String: AnyStruct}] = []
    for winner in winners {
        result.append({
            "poolID": winner.poolID,
            "round": winner.round,
            "winnerReceiverID": winner.winnerReceiverID,
            "amount": winner.amount,
            "nftIDs": winner.nftIDs,
            "timestamp": winner.timestamp,
            "blockHeight": winner.blockHeight
        })
    }

    return result
}
