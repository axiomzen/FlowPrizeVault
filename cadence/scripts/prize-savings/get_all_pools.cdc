import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Get all pool IDs in the PrizeSavings contract
///
/// Returns: Array of pool IDs
access(all) fun main(): [UInt64] {
    return PrizeSavings.getAllPoolIDs()
}

