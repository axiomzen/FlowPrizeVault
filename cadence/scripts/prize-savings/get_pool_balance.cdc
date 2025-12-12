import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Get user's balance in a PrizeSavings pool
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: PoolBalance struct with deposits, prizes, savings, and total balance
access(all) fun main(address: Address, poolID: UInt64): PrizeSavings.PoolBalance {
    let collectionRef = getAccount(address)
        .capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
            PrizeSavings.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")
    
    return collectionRef.getPoolBalance(poolID: poolID)
}

