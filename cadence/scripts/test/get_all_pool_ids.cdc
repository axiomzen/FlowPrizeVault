import "PrizeSavings"

/// Returns all pool IDs from the PrizeSavings contract
access(all) fun main(): [UInt64] {
    return PrizeSavings.getAllPoolIDs()
}

