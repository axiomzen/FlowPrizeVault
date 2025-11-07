import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Get all pool IDs
///
/// Returns: Array of all pool IDs
access(all) fun main(): [UInt64] {
    return PrizeVaultModular.getAllPoolIDs()
}

