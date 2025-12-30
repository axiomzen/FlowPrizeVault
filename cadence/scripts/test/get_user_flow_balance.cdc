import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Get a user's FLOW token wallet balance (not pool balance)
///
/// Parameters:
/// - address: The user's address
///
/// Returns: The FLOW token balance in the user's wallet
access(all) fun main(address: Address): UFix64 {
    let account = getAccount(address)
    
    if let vaultRef = account.capabilities.borrow<&{FungibleToken.Balance}>(
        /public/flowTokenBalance
    ) {
        return vaultRef.balance
    }
    
    return 0.0
}

