import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"

/// Set the treasury recipient for automatic forwarding during syncWithYieldSource.
/// 
/// Once set, treasury funds are automatically forwarded to the recipient
/// whenever syncWithYieldSource() is called (during deposits, withdrawals, etc.)
///
/// Parameters:
/// - poolID: The pool to configure
/// - recipientAddress: Address to receive treasury funds
/// - receiverPath: Public path to the FungibleToken.Receiver capability
///
/// To disable forwarding, use clear_treasury_recipient.cdc
transaction(poolID: UInt64, recipientAddress: Address, receiverPath: PublicPath) {
    let adminRef: auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found. Deploy contract and setup admin first.")
    }
    
    execute {
        let recipientAccount = getAccount(recipientAddress)
        let receiverCap = recipientAccount.capabilities.get<&{FungibleToken.Receiver}>(receiverPath)
        
        assert(receiverCap.check(), message: "Invalid receiver capability at the specified path")
        
        self.adminRef.setPoolTreasuryRecipient(
            poolID: poolID,
            recipientCap: receiverCap
        )
    }
}

