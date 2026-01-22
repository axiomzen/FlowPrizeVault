import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import FungibleToken from "FungibleToken"

/// Set the protocol recipient for automatic forwarding during syncWithYieldSource.
/// 
/// Once set, protocol funds are automatically forwarded to the recipient
/// whenever syncWithYieldSource() is called (during deposits, withdrawals, etc.)
///
/// Parameters:
/// - poolID: The pool to configure
/// - recipientAddress: Address to receive protocol funds
/// - receiverPath: Public path to the FungibleToken.Receiver capability
///
/// To disable forwarding, use clear_protocol_fee_recipient.cdc
transaction(poolID: UInt64, recipientAddress: Address, receiverPath: PublicPath) {
    let adminRef: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found. Deploy contract and setup admin first.")
    }
    
    execute {
        let recipientAccount = getAccount(recipientAddress)
        let receiverCap = recipientAccount.capabilities.get<&{FungibleToken.Receiver}>(receiverPath)
        
        assert(receiverCap.check(), message: "Invalid receiver capability at the specified path")
        
        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: receiverCap
        )
    }
}

