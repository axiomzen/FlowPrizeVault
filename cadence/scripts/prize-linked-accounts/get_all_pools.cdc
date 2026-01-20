import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get all pool IDs in the PrizeLinkedAccounts contract
///
/// Returns: Array of pool IDs
access(all) fun main(): [UInt64] {
    return PrizeLinkedAccounts.getAllPoolIDs()
}

