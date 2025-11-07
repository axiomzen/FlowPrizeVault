import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"

/// Setup admin resource for PrizeVaultModular
/// 
/// **CRITICAL**: This should only be called once after contract deployment.
/// The admin resource will be stored in the caller's account storage.
/// 
/// **Security Best Practices**:
/// - Use a multi-sig wallet account for production
/// - Use a DAO governance contract account
/// - Never use a single private key controlled address
/// 
/// After setup, you can:
/// - Use the admin resource directly from storage
/// - Publish a capability for delegation (optional)
transaction() {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if admin already exists
        if signer.storage.borrow<&PrizeVaultModular.Admin>(from: PrizeVaultModular.AdminStoragePath) != nil {
            log("⚠️  Admin resource already exists, skipping")
            return
        }
        
        // Create and store admin resource
        let admin <- PrizeVaultModular.createAdmin()
        signer.storage.save(<- admin, to: PrizeVaultModular.AdminStoragePath)
        
        log("✅ Admin resource created")
    }
}

