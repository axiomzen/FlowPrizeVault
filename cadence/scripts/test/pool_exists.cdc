import "PrizeSavings"

/// Checks if a pool with the given ID exists
access(all) fun main(poolID: UInt64): Bool {
    return PrizeSavings.borrowPool(poolID: poolID) != nil
}

