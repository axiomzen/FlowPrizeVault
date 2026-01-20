import "PrizeLinkedAccounts"

/// Returns all pool IDs from the PrizeLinkedAccounts contract
access(all) fun main(): [UInt64] {
    return PrizeLinkedAccounts.getAllPoolIDs()
}

