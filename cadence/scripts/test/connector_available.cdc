import "PrizeLinkedAccounts"
import "PLAPoolConnector"

/// Returns the available balance from a PLAPoolConnector.Connector for a user's pool position.
///
access(all) fun main(userAddress: Address, poolID: UInt64): UFix64 {
    let account = getAccount(userAddress)
    let collectionRef = account.capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
        PrizeLinkedAccounts.PoolPositionCollectionPublicPath
    ) ?? panic("No PoolPositionCollection found for address ".concat(userAddress.toString()))

    let balance = collectionRef.getPoolBalance(poolID: poolID)
    return balance.totalBalance
}
