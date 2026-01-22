import "PrizeLinkedAccounts"

/// Get the number of pools in the PrizeLinkedAccounts contract
access(all) fun main(): Int {
    return PrizeLinkedAccounts.getAllPoolIDs().length
}

