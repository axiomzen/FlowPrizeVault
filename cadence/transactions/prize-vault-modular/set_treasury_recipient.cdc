import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"

/// Set the treasury recipient for automatic forwarding during processRewards.
/// 
/// **SECURITY MODEL**: This function can ONLY be called by borrowing Admin
/// directly from storage - meaning only the account owner (private key holder)
/// can execute this transaction. No capability delegation is possible.
/// 
/// This is MORE secure than CriticalOps entitlement because:
/// - CriticalOps can be delegated via capabilities
/// - Direct storage access requires the account's private key(s)
/// 
/// For multi-sig protection, use a multi-sig account to store the Admin resource.
///
/// Example flow:
/// 1. Account owner calls this once to set recipient address
/// 2. Every processRewards() automatically forwards treasury to recipient
/// 3. No further action needed - fully automated
transaction(poolID: UInt64, recipientAddress: Address, receiverPath: PublicPath) {
    let adminRef: &PrizeSavings.Admin
    let signerAddress: Address
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow directly from storage - only account owner can do this
        self.adminRef = signer.storage.borrow<&PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found. Call setup_admin first.")
        
        self.signerAddress = signer.address
    }
    
    execute {
        // Get the recipient's receiver capability
        let recipientAccount = getAccount(recipientAddress)
        let receiverCap = recipientAccount.capabilities.get<&{FungibleToken.Receiver}>(receiverPath)
        
        assert(receiverCap.check(), message: "Invalid receiver capability at the specified path")
        
        self.adminRef.setPoolTreasuryRecipient(
            poolID: poolID,
            recipientCap: receiverCap,
            updatedBy: self.signerAddress
        )
        
        log("✅ Treasury auto-forwarding enabled to: ".concat(recipientAddress.toString()))
    }
}

