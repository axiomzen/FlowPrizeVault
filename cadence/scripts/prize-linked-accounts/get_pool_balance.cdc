import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Get user's balance in a PrizeLinkedAccounts pool
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: PoolBalance struct with deposits, prizes, rewards, and total balance
access(all) fun main(address: Address, poolID: UInt64): PrizeLinkedAccounts.PoolBalance {
    let collectionRef = getAccount(address)
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")
    
    return collectionRef.getPoolBalance(poolID: poolID)
}

