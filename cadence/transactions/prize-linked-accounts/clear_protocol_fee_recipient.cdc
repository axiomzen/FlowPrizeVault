import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import FungibleToken from "FungibleToken"

/// Clear the protocol recipient to disable automatic forwarding.
/// 
/// When no recipient is set, protocol allocation stays in the yield source
/// as future yield (not lost, just not forwarded).
///
/// Parameters:
/// - poolID: The pool to configure
transaction(poolID: UInt64) {
    let adminRef: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin
    
    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found. Deploy contract and setup admin first.")
    }
    
    execute {
        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: nil
        )
    }
}

