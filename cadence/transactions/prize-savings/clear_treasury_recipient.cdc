import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"

/// Clear the treasury recipient to disable automatic forwarding.
/// 
/// When no recipient is set, treasury allocation stays in the yield source
/// as future yield (not lost, just not forwarded).
///
/// Parameters:
/// - poolID: The pool to configure
transaction(poolID: UInt64) {
    let adminRef: auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin
    
    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.OwnerOnly) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found. Deploy contract and setup admin first.")
    }
    
    execute {
        self.adminRef.setPoolTreasuryRecipient(
            poolID: poolID,
            recipientCap: nil
        )
    }
}

