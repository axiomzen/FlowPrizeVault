import "PrizeLinkedAccounts"

/// Check if a pool is in intermission (between rounds, activeRound is nil)
access(all) fun main(poolID: UInt64): Bool {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return poolRef.isInIntermission()
}
