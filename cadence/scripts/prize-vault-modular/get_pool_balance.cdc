import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Get user's balance in a modular pool
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: PoolBalance struct with deposits, prizes, savings, and pending interest
access(all) fun main(address: Address, poolID: UInt64): PrizeVaultModular.PoolBalance {
    let collectionRef = getAccount(address)
        .capabilities.borrow<&{PrizeVaultModular.PoolPositionCollectionPublic}>(
            PrizeVaultModular.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found")
    
    return collectionRef.getPoolBalance(poolID: poolID)
}

