import "PrizeSavings"

/// Get the number of pools in the PrizeSavings contract
access(all) fun main(): Int {
    return PrizeSavings.getAllPoolIDs().length
}

