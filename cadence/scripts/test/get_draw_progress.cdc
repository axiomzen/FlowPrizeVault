import "PrizeSavings"

/// Get the draw progress for a pool (0.0 to 1.0+)
/// Returns info about how far through the current draw period we are
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return {
        "drawProgress": poolRef.getDrawProgressPercent(),
        "timeUntilDraw": poolRef.getTimeUntilNextDraw()
    }
}
