import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Get the balance of a pool's test yield vault
///
/// Parameters:
/// - address: The address where the yield vault is stored (deployer)
/// - poolIndex: The index of the pool's yield vault
///
/// Returns: The balance of the yield vault
access(all) fun main(address: Address, poolIndex: Int): UFix64 {
    let account = getAccount(address)
    
    // Construct the storage path for this pool's yield vault
    let vaultPath = StoragePath(identifier: "testYieldVault_".concat(poolIndex.toString()))!
    
    // Try to borrow the vault balance
    if let vaultRef = getAuthAccount<auth(Storage) &Account>(address)
        .storage.borrow<&FlowToken.Vault>(from: vaultPath) {
        return vaultRef.balance
    }
    
    return 0.0
}
