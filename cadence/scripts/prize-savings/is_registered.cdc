import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Check if a user is registered with a pool
///
/// Parameters:
/// - address: The account address to check
/// - poolID: The pool ID to check registration for
///
/// Returns: Boolean indicating if the user is registered
access(all) fun main(address: Address, poolID: UInt64): Bool {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
    if poolRef == nil {
        return false
    }
    
    return poolRef!.isUserRegistered(userAddress: address)
}
