import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Get the balance of a pool's test yield vault using a configurable prefix
///
/// Parameters:
/// - address: The address where the yield vault is stored (deployer)
/// - poolIndex: The index of the pool's yield vault
/// - vaultPrefix: The storage path prefix (e.g., "testYieldVaultSlippage_")
///
/// Returns: The balance of the yield vault
access(all) fun main(address: Address, poolIndex: Int, vaultPrefix: String): UFix64 {
    let account = getAuthAccount<auth(Storage) &Account>(address)

    // Construct the storage path for this pool's yield vault
    let vaultPath = StoragePath(identifier: vaultPrefix.concat(poolIndex.toString()))!

    // Try to borrow the vault balance
    if let vaultRef = account.storage.borrow<&FlowToken.Vault>(from: vaultPath) {
        return vaultRef.balance
    }

    return 0.0
}
