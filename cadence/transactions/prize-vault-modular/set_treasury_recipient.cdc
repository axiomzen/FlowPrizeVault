import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"

/// Set the treasury recipient for automatic forwarding during processRewards.
/// 
/// **SECURITY MODEL**: This function requires OwnerOnly entitlement which is
/// NEVER issued via capabilities. Only the account owner (private key holder)
/// can execute this transaction via direct storage access.
/// 
/// This is MORE secure than ConfigOps/CriticalOps because:
/// - Those entitlements could theoretically be delegated via capabilities
/// - OwnerOnly is explicitly never issued as a capability
/// - Direct storage access requires the account's private key(s)
/// 
/// For multi-sig protection, use a multi-sig account to store the Admin resource.
///
/// Example flow:
/// 1. Account owner calls this once to set recipient address
/// 2. Every processRewards() automatically forwards treasury to recipient
/// 3. No further action needed - fully automated
transaction(poolID: UInt64, recipientAddress: Address, receiverPath: PublicPath) {
    let adminRef: auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow with OwnerOnly entitlement - only account owner can do this
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found. Call setup_admin first.")
    }
    
    execute {
        // Get the recipient's receiver capability
        let recipientAccount = getAccount(recipientAddress)
        let receiverCap = recipientAccount.capabilities.get<&{FungibleToken.Receiver}>(receiverPath)
        
        assert(receiverCap.check(), message: "Invalid receiver capability at the specified path")
        
        self.adminRef.setPoolTreasuryRecipient(
            poolID: poolID,
            recipientCap: receiverCap
        )
        
        log("✅ Treasury auto-forwarding enabled to: ".concat(recipientAddress.toString()))
    }
}

