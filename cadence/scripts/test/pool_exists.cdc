import "PrizeLinkedAccounts"

/// Checks if a pool with the given ID exists
access(all) fun main(poolID: UInt64): Bool {
    return PrizeLinkedAccounts.borrowPool(poolID: poolID) != nil
}

