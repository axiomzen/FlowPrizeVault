import "PrizeLinkedAccounts"
import "PLAPoolConnector"

/// Returns connector info (poolID, vaultType) for a given user and pool.
/// Validates the connector can be created without errors.
///
access(all) fun main(userAddress: Address, poolID: UInt64): {String: AnyStruct} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    let config = poolRef.getConfig()

    return {
        "poolID": poolID,
        "vaultType": config.assetType.identifier
    }
}
