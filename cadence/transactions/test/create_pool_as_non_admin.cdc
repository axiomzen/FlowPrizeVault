import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"
import "DeFiActions"

/// Transaction to attempt pool creation as non-admin (should fail)
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Try to borrow admin resource from non-admin account
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource - expected failure for non-admin")
        
        // If we get here, it means the non-admin somehow has admin access
        panic("Non-admin should not have admin access")
    }
}

